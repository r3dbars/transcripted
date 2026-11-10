import Foundation

@MainActor
func testAppLogSinkOrdering() async {
    await runSuite("AppLogSink retains launch messages after delayed initialization in caller order") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLogSinkOrdering-\(UUID().uuidString)", isDirectory: true)
        defer { removeAppLogSinkFixture(root, prefix: "AppLogSinkOrdering-") }
        let logURL = root.appendingPathComponent("debug.log")
        let gate = AppLogSinkInitializationGate()
        let dependency = Task { await gate.wait() }
        await gate.waitUntilWaiting()
        let sink = AppLogSink(logFileURL: logURL, initialWriteDependency: dependency)
        let messages = (0..<20).map { "synthetic launch step \($0)" }
        for message in messages { sink.log(message) }

        await gate.release()
        await sink.flush()

        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        assertTrue(lines.first?.hasPrefix("--- Session started ") == true,
                   "the session marker must precede launch messages")
        assertEqual(Array(lines.dropFirst()), sink.entries,
                    "every admitted message must reach disk in the same order as memory")
        assertEqual(lines.count, messages.count + 1,
                    "initialization must not drop or duplicate the first messages")
    }

    await runSuite("AppLogSink flush waits for an empty session's initialization") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLogSinkEmptySession-\(UUID().uuidString)", isDirectory: true)
        defer { removeAppLogSinkFixture(root, prefix: "AppLogSinkEmptySession-") }
        let logURL = root.appendingPathComponent("debug.log")
        let sink = AppLogSink(logFileURL: logURL)
        await sink.flush()
        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        assertTrue(content.contains("--- Session started "), "flush must include the session marker")
        assertEqual(sink.entries, [], "the session marker must not become a user log message")
    }
}

private func removeAppLogSinkFixture(_ root: URL, prefix: String) {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath()
    let resolved = root.resolvingSymlinksInPath()
    guard root.lastPathComponent.hasPrefix(prefix),
          UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
          resolved.deletingLastPathComponent() == temporaryRoot,
          resolved.lastPathComponent == root.lastPathComponent else {
        assertTrue(false, "refusing to remove a fixture outside its owned temporary root")
        return
    }
    guard fileManager.fileExists(atPath: root.path) else { return }
    do {
        try fileManager.removeItem(at: root)
    } catch {
        assertTrue(false, "owned AppLogSink fixture cleanup failed")
    }
}

private actor AppLogSinkInitializationGate {
    private var released = false
    private var waiting = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingObserver: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        waiting = true
        waitingObserver?.resume()
        waitingObserver = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilWaiting() async {
        guard !waiting else { return }
        await withCheckedContinuation { waitingObserver = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
