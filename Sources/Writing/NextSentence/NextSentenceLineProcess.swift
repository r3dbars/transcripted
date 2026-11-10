import Foundation

/// A child process we talk to over stdin/stdout, one JSON object per line.
/// Used for the bundled `transcripted-mcp` search helper and for the `claude` CLI.
/// I/O runs on its own queue; `onLine` is called on that queue, so callers hop to the main actor.
final class NextSentenceLineProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    private var lineHandler: (([String: Any]) -> Void)?
    // The following state belongs to queue, alongside the stdout buffer.
    private var outputEnded = false
    private var endHandler: EndCallback?
    private var endWaiters: [CheckedContinuation<Void, Never>] = []
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, arguments: [String], environment: [String: String] = [:], workingDirectory: URL? = nil, label: String) {
        queue = DispatchQueue(label: "transcripted.next-sentence.\(label)")
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.exited = true
                let waiters = self.exitWaiters
                self.exitWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.queue.async { self.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                self.errorTail.append(data)
                if self.errorTail.count > 4_096 { self.errorTail = self.errorTail.suffix(4_096) }
            }
        }
        try process.run()
    }

    /// Replaces the line handler. Lines that arrived before a handler was set are dropped.
    func onLine(_ handler: (([String: Any]) -> Void)?) {
        lock.lock(); lineHandler = handler; lock.unlock()
    }

    /// Runs after stdout's final JSON frame, including when the child ended
    /// before this handler was installed. No child output is included.
    func onOutputEnd(_ handler: (() -> Void)?) {
        let callback = handler.map(EndCallback.init)
        queue.async {
            self.endHandler = callback
            if self.outputEnded { callback?.call() }
        }
    }

    /// Waits until buffered output and its end callback have been delivered.
    func waitForOutputEnd() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.outputEnded { continuation.resume() }
                else { self.endWaiters.append(continuation) }
            }
        }
    }

    /// Waits for a started child to exit, then drains its output callbacks.
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.exited { continuation.resume() }
                else { self.exitWaiters.append(continuation) }
            }
        }
        await waitForOutputEnd()
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    /// The last few KB the process wrote to stderr, for error messages.
    func stderrTail() -> String {
        queue.sync { String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        queue.async { self.finishOutput() }
    }

    private func receive(_ data: Data) {
        guard !outputEnded else { return }
        if data.isEmpty {
            // A final complete JSON object need not have a trailing newline.
            if !buffer.isEmpty { emit(buffer); buffer.removeAll() }
            finishOutput()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            emit(line)
        }
    }

    private func emit(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        lock.lock(); let handler = lineHandler; lock.unlock()
        handler?(object)
    }

    private func finishOutput() {
        guard !outputEnded else { return }
        outputEnded = true
        endHandler?.call()
        let waiters = endWaiters
        endWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Carries registration across queues; callbacks are invoked only on queue.
    private final class EndCallback: @unchecked Sendable {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        func call() { handler() }
    }
}
