// AppLogger.swift
// Shared logging service — tracks every user action with timestamps
// Writes to both in-app debug panel and ~/draft-debug.log

import Foundation
import SwiftUI

private actor AppLogFileWriter {
    private var logPath: String?
    private var handle: FileHandle?

    func reset(at path: String) {
        logPath = path
        closeHandle()

        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64, size > DraftConstants.logRotationThreshold {
                if let data = fm.contents(atPath: path),
                   let content = String(data: data, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                    let kept = lines.suffix(DraftConstants.logRotationKeepLines).joined(separator: "\n")
                    try? kept.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            // File exists and is either small enough or just rotated — open for append
        } else {
            fm.createFile(atPath: path, contents: nil)
        }

        openHandleIfNeeded()
    }

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        openHandleIfNeeded()
        guard let data = line.data(using: .utf8), let handle else { return }
        handle.write(data)
    }

    private func openHandleIfNeeded() {
        guard handle == nil, let path = logPath else { return }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
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
class AppLogger: ObservableObject {
    @Published var entries: [String] = []

    private let logFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/draft-debug.log"
    }()
    private let fileWriter = AppLogFileWriter()
    private var lastLogByKey: [String: CFAbsoluteTime] = [:]

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

    func log(_ message: String) {
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

    /// Logs at most once per key in the provided interval.
    /// Useful for high-frequency callbacks (speech partials, streaming updates).
    func logThrottled(_ message: String, key: String, minimumInterval: TimeInterval = 0.25) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastLogByKey[key], now - last < minimumInterval {
            return
        }
        lastLogByKey[key] = now
        log(message)
    }
}
