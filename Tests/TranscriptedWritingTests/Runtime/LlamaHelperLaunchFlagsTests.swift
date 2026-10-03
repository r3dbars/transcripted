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
        "The helper's prompt cache is bounded and holds three worst-case entries of the largest model this Mac may run",
        arguments: [8, 16, 18, 24, 32, 64, 128] as [UInt64]
    )
    func promptCacheIsBounded(gibibytes: UInt64) throws {
        let memory = gibibytes * Self.gib
        let arguments = Self.launch(physicalMemoryBytes: memory)
        #expect(arguments.filter { $0 == "--cache-ram" }.count == 1)
        let mib = try #require(Self.value(after: "--cache-ram", in: arguments).flatMap(Int.init))
        #expect(mib > 0)
        let worstCaseEntryMiB = WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: memory) ? 330 : 160
        #expect(mib >= 3 * worstCaseEntryMiB)
        // Far under the pinned build's 8 GiB default.
        #expect(mib <= 2_048)
        #expect(!arguments.contains("--ctx-checkpoints"))
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
        #expect(argv.contains("--cache-ram "))
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
