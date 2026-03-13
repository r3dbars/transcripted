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

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if handle == nil {
                handle = try? FileHandle(forWritingTo: fileURL)
            }
            handle?.seekToEndOfFile()
            handle?.write(lineData)
        } else {
            try? lineData.write(to: fileURL)
            handle = try? FileHandle(forWritingTo: fileURL)
        }
    }

    deinit {
        try? handle?.close()
    }
}
