import Foundation

/// Writes structured log entries as JSON Lines to ~/Library/Logs/Transcripted/app.jsonl
///
/// Design decisions:
/// - JSON Lines format: one JSON object per line, machine-parseable, grep-friendly
/// - Rolling truncation: max 2000 entries, trims oldest 500 when full (checked every 100 writes)
/// - Thread safety via serial DispatchQueue (.async writes) — NEVER use locks here
///   because CoreAudio callbacks run on real-time threads where locks cause priority inversion
/// - Short JSON keys to minimize file size: t=timestamp, l=level, s=subsystem, m=message, d=data
final class FileLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.transcripted.filelogger", qos: .utility)
    private let logFileURL: URL
    private var fileHandle: FileHandle?
    private var writeCount: Int = 0
    private let maxEntries = 2000
    private let trimTarget = 1500   // Keep this many after trim
    private let trimCheckInterval = 100

    private lazy var dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("app.jsonl")

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Open file handle for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    /// Write a log entry asynchronously (non-blocking)
    func write(level: String, subsystem: String, message: String, metadata: [String: String]?) {
        queue.async { [weak self] in
            self?.writeSync(level: level, subsystem: subsystem, message: message, metadata: metadata)
        }
    }

    /// Synchronous flush — blocks until all pending writes complete
    /// Call from applicationWillTerminate
    func flush() {
        queue.sync { [weak self] in
            self?.fileHandle?.synchronizeFile()
        }
    }

    // MARK: - Private

    private func writeSync(level: String, subsystem: String, message: String, metadata: [String: String]?) {
        let timestamp = dateFormatter.string(from: Date())

        // Build compact JSON manually for performance (avoid JSONEncoder overhead per-line)
        var json = "{\"t\":\"\(escapeJSON(timestamp))\",\"l\":\"\(escapeJSON(level))\",\"s\":\"\(escapeJSON(subsystem))\",\"m\":\"\(escapeJSON(message))\""

        if let metadata = metadata, !metadata.isEmpty {
            let pairs = metadata.map { "\"\(escapeJSON($0.key))\":\"\(escapeJSON($0.value))\"" }
            json += ",\"d\":{\(pairs.joined(separator: ","))}"
        }

        json += "}\n"

        if let data = json.data(using: .utf8) {
            fileHandle?.write(data)
        }

        writeCount += 1
        if writeCount % trimCheckInterval == 0 {
            trimIfNeeded()
        }
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: logFileURL),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > maxEntries else { return }

        // Keep the most recent entries
        let trimmed = Array(lines.suffix(trimTarget))
        let newContent = trimmed.joined(separator: "\n") + "\n"

        // Close handle, rewrite file, reopen
        fileHandle?.closeFile()

        try? newContent.write(to: logFileURL, atomically: true, encoding: .utf8)

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    deinit {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
    }
}
