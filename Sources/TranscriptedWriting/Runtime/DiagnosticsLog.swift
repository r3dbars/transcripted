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
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {
        // Beside Transcripted's other logs (docs/storage-paths.md) rather than
        // under ~/Library/Logs as in Tilde; see the ledger's rename table.
        self.logURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Transcripted/logs")
            .appendingPathComponent("writing-diagnostics.log")
        // Transcripted rule (CLAUDE.md, "Harnesses must not touch real user
        // state"): test and smoke runs never write the real log. Same checks
        // as TranscriptedCore's FileLogger, plus Swift Testing's helper.
        self.enabled = !Self.shouldDisableFileWrites(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        )
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

    init(logURL: URL, enabled: Bool = true) {
        self.logURL = logURL
        self.enabled = enabled
    }

    func record(_ event: String, metadata: [String: String] = [:]) {
        guard enabled else { return }
        queue.async { [self, logURL] in
            do {
                let line = format(event: event, metadata: metadata)
                guard let handle = SecureLocalStorage.openFileForAppending(at: logURL) else {
                    return
                }
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
