// lint-fixture-path: Tests/MeetingPromptDetectorTests.swift
// Shape of 5ed983633^: a fixed ~100 ms wait written as a loop with no way out.
@MainActor
private func waitForPromptEvaluation() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

func testClockWaits() async {
    await runSuite("clock and run loop waits are fixed too") {
        try? await ContinuousClock().sleep(for: .milliseconds(50))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
