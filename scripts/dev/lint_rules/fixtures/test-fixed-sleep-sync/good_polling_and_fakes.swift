// lint-fixture-path: Tests/MeetingPromptDetectorTests.swift
// A loop that can stop early polls a condition; a fake type's method that
// sleeps simulates slow work.
@MainActor
private func waitForPromptEvaluation(until done: () -> Bool) async {
    for _ in 0..<200 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func waitForDrain(_ box: Box) async {
    for _ in 0..<200 where box.pending > 0 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

final class SlowLookupFake {
    func lookup() async -> Int {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return 42
    }
}
