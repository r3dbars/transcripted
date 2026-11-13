import Foundation

private final class ErrorResultObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (isError: Bool, resultIsMissing: Bool, stderr: String)?

    func record(isError: Bool, resultIsMissing: Bool, stderr: String) {
        lock.lock()
        value = (isError, resultIsMissing, stderr)
        lock.unlock()
    }

    func snapshot() -> (isError: Bool, resultIsMissing: Bool, stderr: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func testNextSentenceLineProcess() {
    runSuite("A JSON error callback can read stderrTail and complete without a result string") {
        let process = NextSentenceLineProcess(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s\n", "{\"type\":\"result\",\"is_error\":true}"],
            environment: [:],
            label: "owned.test.error-result-callback"
        )
        let completion = DispatchSemaphore(value: 0)
        let observation = ErrorResultObservation()
        process.onLine { object in
            guard object["type"] as? String == "result" else { return }
            let stderr = process.stderrTail()
            observation.record(
                isError: object["is_error"] as? Bool == true,
                resultIsMissing: object["result"] as? String == nil,
                stderr: stderr
            )
            completion.signal()
        }
        defer {
            process.onLine(nil)
            process.terminate()
        }

        do {
            try process.start()
        } catch {
            assertTrue(false, "The owned printf fixture must start")
            return
        }

        // This is a completion guard, not an assertion about elapsed time.
        let completed = completion.wait(timeout: .now() + 15) == .success
        assertTrue(completed, "The actual line callback must finish reading stderrTail")
        guard completed, let result = observation.snapshot() else { return }
        assertTrue(result.isError, "The callback receives the synthetic error result")
        assertTrue(result.resultIsMissing, "The fixture reaches the missing-result-string case")
        assertEqual(result.stderr, "", "An empty stderr stream is a valid tail")
    }
}
