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
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    // MARK: - Subsystem Loggers

    static let audio = SubsystemLogger("audio")
    static let audioMic = SubsystemLogger("audio.mic")
    static let audioSystem = SubsystemLogger("audio.system")
    static let transcription = SubsystemLogger("transcription")
    static let pipeline = SubsystemLogger("pipeline")
    static let speakers = SubsystemLogger("speaker-db")
    static let services = SubsystemLogger("services")
    static let ui = SubsystemLogger("ui")
    static let stats = SubsystemLogger("stats")
    static let app = SubsystemLogger("app")

    let fileLogger: FileLogger

    private init() {
        fileLogger = FileLogger()
    }

    func log(level: String, subsystem: String, message: String, metadata: [String: String]?) {
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
        os_log("%{public}@", log: osLog, type: logType, "[\(subsystem)] \(message)\(metadataString(metadata))")
    }

    /// Synchronous flush — call from applicationWillTerminate
    func flush() {
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
struct SubsystemLogger: Sendable {
    let subsystem: String

    init(_ subsystem: String) {
        self.subsystem = subsystem
    }

    func debug(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "debug", subsystem: subsystem, message: message, metadata: metadata)
    }

    func info(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "info", subsystem: subsystem, message: message, metadata: metadata)
    }

    func warning(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "warning", subsystem: subsystem, message: message, metadata: metadata)
    }

    func error(_ message: String, _ metadata: [String: String]? = nil) {
        AppLogger.shared.log(level: "error", subsystem: subsystem, message: message, metadata: metadata)
    }
}
