// AppLogger.swift
// Shared logging service — tracks every user action with timestamps
// Writes to both in-app debug panel and ~/draft-debug.log

import Foundation
import SwiftUI

@MainActor
class AppLogger: ObservableObject {
    @Published var entries: [String] = []

    private let logFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/draft-debug.log"
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Background queue for file I/O — keeps main thread responsive
    private let fileQueue = DispatchQueue(label: "draft.logger.file", qos: .utility)

    init() {
        // Clear log file on launch (on background queue)
        let path = logFilePath
        fileQueue.async {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        entries.append(entry)

        // File I/O on background queue — never blocks the main thread
        let line = entry + "\n"
        let path = logFilePath
        fileQueue.async {
            if let data = line.data(using: .utf8),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }

        // Keep last 200 entries to avoid unbounded growth
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }
}
