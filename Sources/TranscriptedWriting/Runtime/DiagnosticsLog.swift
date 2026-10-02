import Foundation
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    /// Discards every event instead of writing it. For callers — like the
    /// replay-eval CLI — whose contract promises no side effects beyond
    /// their own single output: they must never contaminate the shared
    /// operational diagnostics log with synthetic timing/rejection entries.
    static let disabled = DiagnosticsLog(logURL: FileManager.default.temporaryDirectory, enabled: false)

    private let queue = DispatchQueue(label: "com.justinbetker.draft.diagnostics")
    private let logURL: URL
    private let enabled: Bool
    /// Past this size the log rolls to `<name>.1` before the next append, so
    /// disk use stays near twice the cap. Same rename-to-`.1` strategy as the
    /// app's observability logs; Runtime can't import that helper.
    private let maxBytes: UInt64
    static let defaultMaxBytes: UInt64 = 4 * 1024 * 1024
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {
        // Beside Transcripted's other logs (docs/storage-paths.md) rather than
        // under ~/Library/Logs as in Tilde; see the ledger's rename table.
        self.logURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Transcripted/logs")
            .appendingPathComponent("writing-diagnostics.log")
        // Transcripted rule (AGENTS.md, "Harnesses must not touch real user
        // state"): test and smoke runs never write the real log. Same checks
        // as TranscriptedCore's FileLogger, plus Swift Testing's helper.
        self.enabled = !Self.shouldDisableFileWrites(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        )
        self.maxBytes = Self.defaultMaxBytes
    }

    static func shouldDisableFileWrites(environment: [String: String], arguments: [String]) -> Bool {
        if let flag = environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"],
           ["1", "true", "yes", "on"].contains(flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        if let executable = arguments.first,
           executable.contains(".xctest") || executable.hasSuffix("swiftpm-testing-helper") {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    init(logURL: URL, enabled: Bool = true, maxBytes: UInt64 = DiagnosticsLog.defaultMaxBytes) {
        self.logURL = logURL
        self.enabled = enabled
        self.maxBytes = maxBytes
    }

    /// Where the previous generation goes when the log rolls.
    var rolledLogURL: URL { logURL.appendingPathExtension("1") }

    func record(_ event: String, metadata: [String: String] = [:]) {
        guard enabled else { return }
        queue.async { [self, logURL] in
            do {
                let line = format(event: event, metadata: metadata)
                guard let handle = openRollingIfNeeded() else { return }
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Logging must never affect typing.
            }
        }
    }

    /// Blocks until every already-recorded event has reached disk. For
    /// shutdown paths only: an exit racing the async queue would drop the
    /// final events — exactly the crash-vs-quit ambiguity they exist to solve.
    func flush() {
        queue.sync {}
    }

    /// Opens the log for appending, first rolling it to `.1` when it has
    /// reached the cap. The size comes from the opened descriptor, so the
    /// check can't be fooled by a path swapped underneath it; rename(2) moves
    /// a directory entry and never follows a symlink. If the rename fails the
    /// log keeps growing rather than going silent.
    private func openRollingIfNeeded() -> FileHandle? {
        guard let handle = SecureLocalStorage.openFileForAppending(at: logURL) else { return nil }
        guard let size = try? handle.seekToEnd(), size >= maxBytes else { return handle }
        try? handle.close()
        _ = rename(logURL.path, rolledLogURL.path)
        return SecureLocalStorage.openFileForAppending(at: logURL)
    }

    private func format(event: String, metadata: [String: String]) -> String {
        let timestamp = timestampFormatter.string(from: Date())
        let fields = metadata
            .sorted { $0.key < $1.key }
            .map(DiagnosticsMetadataRedactor.logSafeField)
            .joined(separator: " ")
        let safeEvent = DiagnosticsMetadataRedactor.logSafeEvent(event)

        if fields.isEmpty {
            return "\(timestamp) \(safeEvent)\n"
        }

        return "\(timestamp) \(safeEvent) \(fields)\n"
    }
}
