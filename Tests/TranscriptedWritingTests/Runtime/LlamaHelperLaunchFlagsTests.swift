import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The helper's launch flags that keep its CPU and memory bounded without
/// changing what it generates: one server slot, a bounded prompt cache, and
/// idle CPU threads that sleep between tokens.
@Suite("Llama helper launch flags")
struct LlamaHelperLaunchFlagsTests {
    private static let gib: UInt64 = 1024 * 1024 * 1024

    private static func launch(physicalMemoryBytes: UInt64 = 32 * gib) -> [String] {
        LlamaServerProcessHost.launchConfiguration(
            model: "/dev/fd/0",
            port: 17891,
            apiKey: "k3y",
            inheritedEnvironment: [:],
            physicalMemoryBytes: physicalMemoryBytes
        ).arguments
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test("The helper's idle CPU threads sleep between tokens instead of spinning")
    func idleThreadsSleep() {
        let arguments = Self.launch()
        #expect(Self.value(after: "--poll", in: arguments) == "0")
        #expect(arguments.filter { $0 == "--poll" }.count == 1)
    }

    @Test("The helper runs exactly one server slot; the scaffold prewarmer and the engine's early stop rely on it")
    func oneServerSlot() {
        let arguments = Self.launch()
        #expect(Self.value(after: "-np", in: arguments) == "1")
        #expect(!arguments.contains("--parallel"))
        #expect(!arguments.contains("--kv-unified"))
    }

    @Test(
        "The prompt cache is tiered by RAM: big Macs keep the build's default, smaller ones get a bound",
        arguments: [
            (16, 1_024), (24, 1_024), (32, 4_096), (48, 4_096), (64, nil), (128, nil),
        ] as [(UInt64, Int?)]
    )
    func promptCacheIsTiered(gibibytes: UInt64, expectedMiB: Int?) throws {
        let memory = gibibytes * Self.gib
        #expect(LlamaServerProcessHost.promptCacheMiB(physicalMemoryBytes: memory) == expectedMiB)
        let arguments = Self.launch(physicalMemoryBytes: memory)
        if let expectedMiB {
            #expect(arguments.filter { $0 == "--cache-ram" }.count == 1)
            let mib = try #require(Self.value(after: "--cache-ram", in: arguments).flatMap(Int.init))
            #expect(mib == expectedMiB)
            // Three worst-case Qwen entries (~330 MiB each) still fit.
            #expect(mib >= 3 * 330)
        } else {
            // Same as before the cap existed: the build's own 8 GiB default.
            #expect(!arguments.contains("--cache-ram"))
        }
        #expect(!arguments.contains("--ctx-checkpoints"))
    }

    @Test("Just under a tier boundary takes the smaller cache")
    func promptCacheBoundaries() {
        #expect(LlamaServerProcessHost.promptCacheMiB(physicalMemoryBytes: 32 * Self.gib - 1) == 1_024)
        #expect(LlamaServerProcessHost.promptCacheMiB(physicalMemoryBytes: 64 * Self.gib - 1) == 4_096)
    }

    @Test("The bounded cache keeps the existing launch promises")
    func existingPromisesHold() {
        let arguments = Self.launch()
        #expect(Self.value(after: "--host", in: arguments) == "127.0.0.1")
        #expect(Self.value(after: "-c", in: arguments) == "4096")
        #expect(Self.value(after: "--cache-reuse", in: arguments) == "256")
        #expect(arguments.contains("--swa-full"))
        #expect(arguments.contains("--no-webui"))
        #expect(!arguments.contains { $0.contains("k3y") })
    }

    /// Runs the real host against a stand-in helper that records its argv and
    /// exits at once. The retry is held by a manual scheduler, so this sees
    /// exactly one real spawn.
    @Test("The real helper spawn carries the slot, cache and poll flags")
    func realSpawnCarriesFlags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-launch-flags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("argv.txt")
        let helper = directory.appendingPathComponent("fake-llama-server")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        exit 1
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let scheduler = HeldRetries()
        let host = LlamaServerProcessHost(
            port: Int.random(in: 40_000...60_000),
            assetResolver: { .init(binary: helper.path, model: "/nonexistent-model") },
            portListeners: { _ in [] },
            retryScheduler: { delay, fire in scheduler.hold(delay, fire) }
        )
        host.start()
        defer { host.stop() }

        var argv = ""
        for _ in 0..<300 where argv.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            argv = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }
        host.stop()

        try #require(!argv.isEmpty)
        #expect(argv.contains("-np 1"))
        #expect(argv.contains("--poll 0"))
        let cacheMiB = LlamaServerProcessHost.promptCacheMiB(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        #expect(argv.contains("--cache-ram ") == (cacheMiB != nil))
        #expect(!argv.contains("--kv-unified"))
    }
}

private final class HeldRetries: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [@Sendable () -> Void] = []
    func hold(_ delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        lock.withLock { held.append(fire) }
    }
}
