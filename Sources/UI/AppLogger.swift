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

    init() {
        // Clear log file on launch
        FileManager.default.createFile(atPath: logFilePath, contents: nil)
    }

    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        entries.append(entry)
        print("📋 \(entry)")

        // Append to log file for external monitoring
        let line = entry + "\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: logFilePath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }

        // Keep last 200 entries to avoid unbounded growth
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }
}
