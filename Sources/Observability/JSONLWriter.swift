// JSONLWriter.swift
// Shared actor for append-only JSONL file writes.
// Reuses FileHandle across appends to avoid open/seek/close overhead per write.

import Foundation

actor JSONLWriter {
    private let fileURL: URL
    private var handle: FileHandle?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ data: Data) {
        let lineData: Data
        if data.last == 0x0A {
            lineData = data
        } else {
            lineData = data + Data([0x0A])
        }

        // Detect stale file descriptor — file may have been rotated or deleted externally
        if handle != nil && !FileManager.default.fileExists(atPath: fileURL.path) {
            try? handle?.close()
            handle = nil
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        if handle == nil {
            handle = try? FileHandle(forWritingTo: fileURL)
        }

        if let handle {
            LockedFileAppender.append(lineData, to: handle)
        }
    }

    deinit {
        try? handle?.close()
    }
}
