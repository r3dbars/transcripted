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
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
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
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            lock.lock(); let handler = lineHandler; lock.unlock()
            handler?(object)
        }
    }
}
