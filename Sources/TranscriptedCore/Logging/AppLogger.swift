import Foundation
import OSLog

/// Unified logging interface for Transcripted
///
/// Writes to both:
/// 1. os.Logger (Console.app) — for human debugging
/// 2. FileLogger (~/Library/Logs/Transcripted/app.jsonl) — for agent diagnostics
///
/// Usage:
///   AppLogger.audioMic.info("Started", ["sampleRate": "\(format.sampleRate)"])
///   AppLogger.pipeline.error("Transcription failed", ["error": "\(error)"])
public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    // MARK: - Subsystem Loggers

    public static let audio = SubsystemLogger("audio")
    public static let audioMic = SubsystemLogger("audio.mic")
    public static let audioSystem = SubsystemLogger("audio.system")
    public static let transcription = SubsystemLogger("transcription")
    public static let pipeline = SubsystemLogger("pipeline")
    public static let speakers = SubsystemLogger("speaker-db")
    public static let services = SubsystemLogger("services")
    public static let ui = SubsystemLogger("ui")
    public static let stats = SubsystemLogger("stats")
    public static let app = SubsystemLogger("app")

    let fileLogger: FileLogger

    private init() {
        fileLogger = FileLogger()
    }

    public func log(level: String, subsystem: String, message: String, metadata: [String: String]?) {
        // Write to file logger (agent-readable)
        fileLogger.write(level: level, subsystem: subsystem, message: message, metadata: metadata)

        // Write to os.Logger (Console.app)
        let osLog = OSLog(subsystem: "com.transcripted.\(subsystem)", category: subsystem)
        let logType: OSLogType = switch level {
        case "debug": .debug
        case "warning": .error
        case "error": .fault
        default: .info
        }
        // Default to %{private}@ so caller-supplied metadata (paths, titles, errors)
        // is redacted in production system logs. Console.app on a development device
        // can still surface this with `sudo log config --mode "private_data:on"`.
        os_log("%{private}@", log: osLog, type: logType, "[\(subsystem)] \(message)\(metadataString(metadata))")
    }

    /// Synchronous flush — call from applicationWillTerminate
    public func flush() {
        fileLogger.flush()
    }

    private func metadataString(_ metadata: [String: String]?) -> String {
        guard let metadata = metadata, !metadata.isEmpty else { return "" }
        let pairs = metadata.map { "\($0.key)=\($0.value)" }
        return " {\(pairs.joined(separator: ", "))}"
    }
}

/// Lightweight subsystem-scoped logger
/// Provides clean callsite syntax: AppLogger.audioMic.info("Started")
public struct SubsystemLogger: Sendable {
    public let subsystem: String

    public init(_ subsystem: String) {
        self.subsystem = subsystem
    }

    public func debug(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "debug", subsystem: subsystem, message: message, metadata: metadata)
    }

    public func info(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "info", subsystem: subsystem, message: message, metadata: metadata)
    }

    public func warning(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "warning", subsystem: subsystem, message: message, metadata: metadata)
    }

    public func error(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "error", subsystem: subsystem, message: message, metadata: metadata)
    }
}
