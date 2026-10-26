// lint-fixture-path: Tests/MeetingPromptDetectorTests.swift
// Shape of 4ca2f83bd^: a shared helper waits a fixed time before callers assert.
@MainActor
private func waitForPromptEvaluation(extraMilliseconds: UInt64 = 0) async {
    if extraMilliseconds > 0 {
        try? await Task.sleep(nanoseconds: extraMilliseconds * 1_000_000)
    }
}

func testMeetingPromptDetector() async {
    await runSuite("a Meet tab after Not now still prompts") {
        detector.updateMicInputUsers(["com.example.browser.helper"])
        usleep(100_000)
        assertEqual(box.promptCount, 2, "the second prompt arrives")
    }
}
