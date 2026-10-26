// lint-fixture-path: Tests/TranscriptedConstantsTests.swift
// Sleeps that simulate slow work (inside a fake's closure or a raced Task),
// a fake clock's own sleep, and a process watchdog are not waits.
func testTimeouts() async {
    await runSuite("withTimeout cancels work after deadline") {
        let result = try? await TranscriptedConstants.withTimeout(seconds: 0.01) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "late"
        }
        assertNil(result, "timeout returns instead of hanging")
    }

    await runSuite("slow lookup still delivers") {
        let dispatcher = LookupDispatcher(
            lookup: {
                Thread.sleep(forTimeInterval: 0.05)
                return 42
            }
        )
        await dispatcher.drain()
    }

    let winner = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await task.value; return true }
        group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return false }
        return await group.next() ?? false
    }
    assertTrue(winner, "finished before the give-up margin")
}

final class VirtualTestClock: @unchecked Sendable {
    func pause() async {
        try? await Task.sleep(nanoseconds: 0)
    }
}

struct FakeSleeper {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        fputs("FAIL: smoke exceeded its deadline\n", stderr)
        exit(1)
    }
}
