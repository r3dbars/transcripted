import Foundation

func testRuntimeDiagnosticsContextWriter() {
    runSuite("runtime context updates stay off main and preserve submission order") {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = RuntimeContextWriteResult()
        let writer = RuntimeDiagnosticsContextWriter { context in
            if context["session_stage"] == "recording" {
                started.signal()
                // Failure watchdog only; no assertion on scheduling speed.
                _ = resume.wait(timeout: .now() + 30)
            }
            result.append(context, isMainThread: Thread.isMainThread)
            if context["session_stage"] == "idle" {
                finished.signal()
            }
        }
        writer.submit(["session_stage": "recording"])
        guard started.wait(timeout: .now() + 30) == .success else {
            resume.signal()
            assertTrue(false, "the context worker did not start")
            return
        }
        // A stalled preferences provider must not block the next submission.
        writer.submit(["session_stage": "idle"])
        resume.signal()
        guard finished.wait(timeout: .now() + 30) == .success else {
            assertTrue(false, "the context worker did not finish")
            return
        }
        assertEqual(result.contexts, [["session_stage": "recording"], ["session_stage": "idle"]])
        assertFalse(result.usedMainThread, "preferences and Sentry scope updates must run off main")
    }
}

private final class RuntimeContextWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: String]] = []
    private var onMain = false

    func append(_ context: [String: String], isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        values.append(context)
        onMain = onMain || isMainThread
    }

    var contexts: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var usedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMain
    }
}
