// AppLogSink.swift
// Shared logging service — tracks every user action with timestamps.
// Writes to both the in-app debug panel and the app-owned logs folder.
//
// See docs/observability.md for how this fits alongside TranscriptedCore's
// AppLogger, FileLogger, EventReporter, and ReliabilityPacketRecorder.

import Foundation
import SwiftUI
import TranscriptedCore

private actor AppLogSinkFileWriter {
    private var logPath: String?
    private var handle: FileHandle?
    /// Live byte count for the open log. `reset(at:)` seeds it from the file on
    /// disk and `append(_:)` keeps it current, so a resident menubar app trims
    /// mid-session instead of only at launch.
    private var trackedByteCount: UInt64 = 0

    func reset(at path: String) {
        logPath = path
        closeHandle()

        let fm = FileManager.default
        try? fm.createPrivateDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        if fm.fileExists(atPath: path) {
            do {
                let attrs = try fm.attributesOfItem(atPath: path)
                if let size = attrs[.size] as? UInt64, size > TranscriptedConstants.logRotationThreshold {
                    // Trigger (byte size, checked once here at session start) stays
                    // local; the actual read/trim/rewrite mechanics are shared with
                    // TranscriptedCore's FileLogger via LogTailTrimmer.
                    LogTailTrimmer.trimIfNeeded(
                        at: path,
                        maxLines: nil,
                        keepLines: TranscriptedConstants.logRotationKeepLines,
                        filterEmptyLines: false,
                        appendsTrailingNewline: false
                    )
                }
            } catch {
                fputs("⚠️ LOGGER | failed to read log file attributes: \(error.localizedDescription)\n", stderr)
            }
            // File exists and is either small enough or just rotated — open for append
        } else {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        fm.restrictFileToOwnerOnly(at: URL(fileURLWithPath: path))

        trackedByteCount = Self.fileByteCount(at: path)
        openHandleIfNeeded()
    }

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        openHandleIfNeeded()
        guard let data = line.data(using: .utf8), let handle else { return }
        LockedFileAppender.append(data, to: handle)
        trackedByteCount += UInt64(data.count)
        trimIfGrownPastThreshold()
    }

    /// Same trigger and mechanics as `reset(at:)`, re-checked as the file grows.
    /// The handle has to close first: LogTailTrimmer rewrites the file, so an
    /// open append handle would keep seeking past the trimmed end.
    private func trimIfGrownPastThreshold() {
        guard let logPath,
              trackedByteCount > TranscriptedConstants.logRotationThreshold else { return }

        closeHandle()
        LogTailTrimmer.trimIfNeeded(
            at: logPath,
            maxLines: nil,
            keepLines: TranscriptedConstants.logRotationKeepLines,
            filterEmptyLines: false,
            appendsTrailingNewline: false
        )
        trackedByteCount = Self.fileByteCount(at: logPath)
        openHandleIfNeeded()
    }

    private static func fileByteCount(at path: String) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return 0 }
        return size
    }

    private func openHandleIfNeeded() {
        guard handle == nil, let path = logPath else { return }
        handle = FileHandle(forWritingAtPath: path)
        // seekToEnd() (error-returning) instead of the legacy seekToEndOfFile(),
        // which raises an uncatchable ObjC NSException on failure and hard-crashes.
        do {
            try handle?.seekToEnd()
        } catch {
            fputs("⚠️ LOGGER | failed to seek debug log: \(ObservabilityTextRedactor.redact(error.localizedDescription))\n", stderr)
        }
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

@MainActor
class AppLogSink: ObservableObject {
    @Published var entries: [String] = []

    private let logFilePath = FileManager.default.transcriptedLogsDirURL
        .appendingPathComponent("debug.log", isDirectory: false)
        .path
    private let fileWriter = AppLogSinkFileWriter()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init() {
        let path = logFilePath
        Task.detached(priority: .utility) { [fileWriter] in
            await fileWriter.reset(at: path)
            await fileWriter.append("\n--- Session started \(ISO8601DateFormatter().string(from: Date())) ---\n")
        }
    }

    nonisolated static func sanitizedLogMessage(_ message: String) -> String {
        ObservabilityTextRedactor.redact(message)
    }

    func log(_ message: String) {
        let message = Self.sanitizedLogMessage(message)
        guard !message.isEmpty else { return }

        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        entries.append(entry)

        let line = entry + "\n"
        Task.detached(priority: .utility) { [fileWriter] in
            await fileWriter.append(line)
        }

        // Keep last 200 entries to avoid unbounded growth
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }
}
