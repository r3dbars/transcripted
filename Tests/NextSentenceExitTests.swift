import Foundation

func testNextSentenceExit() async {
    for structured in [false, true] {
        await runSuite(structured ? "Structured Claude child exit completes before timeout" : "Streaming Claude child exit completes before timeout") {
            let fixture = NextSentenceExitFixture(script: "IFS= read -r request\nexit 7\n")
            let result = NextSentenceExitResult()
            assertEqual(fixture.started, false, "constructing the client must not start a child")
            if structured {
                fixture.client.structured(.alternatives, prompt: "synthetic request", image: nil) {
                    result.record($0.map { _ in true })
                }
            } else {
                fixture.client.stream(prompt: "synthetic request", image: nil, onText: { _ in }) {
                    result.record($0.map { _ in true })
                }
            }
            await fixture.waitForExit()
            assertEqual(result.outcomes, ["ended"], "exit must finish the request before the timeout callback")
            fixture.timeouts.fire()
            assertEqual(result.outcomes, ["ended"], "the later timeout must not complete the request again")
            await fixture.cleanup()
        }
    }

    for structured in [false, true] {
        await runSuite(structured ? "Structured final JSON wins over EOF without a trailing newline" : "Streaming final result wins over EOF") {
            let payload = structured
                ? #"{"type":"result","is_error":false,"structured_output":{"answer":"synthetic"}}"#
                : #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"synthetic"}}}"#
                    + "\n" + #"{"type":"result","is_error":false}"# + "\n"
            let fixture = NextSentenceExitFixture(script: "IFS= read -r request\nprintf '%s' '\(payload)'\n")
            let result = NextSentenceExitResult()
            if structured {
                fixture.client.structured(.alternatives, prompt: "synthetic request", image: nil) {
                    result.record($0.map { $0["answer"] as? String == "synthetic" })
                }
            } else {
                fixture.client.stream(prompt: "synthetic request", image: nil, onText: { _ in }) {
                    result.record($0.map { $0 == "synthetic" })
                }
            }
            await fixture.waitForExit()
            assertEqual(result.outcomes, ["success"], "the final parsed answer must win before output ends")
            fixture.timeouts.fire()
            assertEqual(result.outcomes, ["success"], "EOF and timeout must not replace a successful answer")
            await fixture.cleanup()
        }
    }

    await runSuite("A late output-end observer still sees the exited child") {
        let fixture = NextSentenceExitFixture(script: "exit 0\n")
        let process = fixture.start()
        await fixture.waitForExit()
        let seen = NextSentenceExitResult()
        process?.onOutputEnd { seen.markEnd() }
        await process?.waitForOutputEnd()
        assertEqual(seen.outcomes, ["ended"], "output closure must be replayed after handler registration")
        await fixture.cleanup()
    }
}

private final class NextSentenceExitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var outcomes: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func markEnd() { lock.lock(); values.append("ended"); lock.unlock() }
    func record(_ result: Result<Bool, Error>) {
        let outcome: String
        switch result {
        case .success(true): outcome = "success"
        case .success(false): outcome = "unexpected_success"
        case .failure(let error):
            if case NextSentenceClaude.Failure.failed(let message) = error,
               message == "Claude stopped before returning an answer." { outcome = "ended" }
            else { outcome = "other_failure" }
        }
        lock.lock(); values.append(outcome); lock.unlock()
    }
}

private final class NextSentenceExitTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [NextSentenceCallbackBox] = []
    func store(_ callback: NextSentenceCallbackBox) { lock.lock(); callbacks.append(callback); lock.unlock() }
    func fire() {
        lock.lock(); let pending = callbacks; callbacks.removeAll(); lock.unlock()
        for callback in pending { callback.call() }
    }
}

private final class NextSentenceExitFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NextSentenceExit-\(UUID().uuidString)", isDirectory: true)
    let timeouts = NextSentenceExitTimeouts()
    private let process: NextSentenceLineProcess
    private let startState = NextSentenceExitStartState()
    private let prepared: Bool
    let client: NextSentenceClaude
    var started: Bool { startState.started }

    init(script: String) {
        let child = root.appendingPathComponent("child.sh")
        var ready = false
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: child, atomically: true, encoding: .utf8)
            ready = true
        } catch { recordFailure("could not prepare the owned synthetic child") }
        prepared = ready
        let isPrepared = ready
        let process = NextSentenceLineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [child.path],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "ENV": "/dev/null", "BASH_ENV": "/dev/null"],
            workingDirectory: root, label: "synthetic-exit"
        )
        self.process = process
        let state = startState
        let timeouts = timeouts
        client = NextSentenceClaude(spawn: { _, _ in
            guard isPrepared else { return nil }
            do { try process.start(); state.didStart(); return process }
            catch { return nil }
        }, background: { _ in }, scheduleTimeout: { _, callback in timeouts.store(callback) })
    }

    func start() -> NextSentenceLineProcess? {
        guard prepared else { return nil }
        do { try process.start(); startState.didStart(); return process }
        catch { recordFailure("could not start the owned synthetic child"); return nil }
    }

    func waitForExit() async {
        guard started else { recordFailure("the synthetic child was not started"); return }
        await process.waitForExit()
    }

    func cleanup() async {
        client.stop()
        if started { process.terminate(); await process.waitForExit() }
        let resolved = root.resolvingSymlinksInPath()
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let prefix = "NextSentenceExit-"
        guard root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              resolved.deletingLastPathComponent() == parent,
              resolved.lastPathComponent == root.lastPathComponent else {
            return recordFailure("refusing to remove a synthetic child outside its owned root")
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { recordFailure("synthetic child fixture cleanup failed") }
    }
}

private final class NextSentenceExitStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func didStart() { lock.lock(); value = true; lock.unlock() }
}
