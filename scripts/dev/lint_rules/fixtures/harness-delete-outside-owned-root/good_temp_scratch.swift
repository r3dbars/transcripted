// lint-fixture-path: Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/Fixture.swift
// Scratch made under temporaryDirectory, a fixed child of an input root, and a
// helper deleting its own parameter (the caller owns that check) are all fine.
import Foundation

struct ScratchUser {
    let fileManager = FileManager.default

    func run(outputURL: URL) throws {
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("qa-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let report = outputURL.appendingPathComponent("summary.json")
        try? fileManager.removeItem(at: report)
        let dbPath = NSTemporaryDirectory() + "qa-\(UUID().uuidString).sqlite"
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: dbPath + suffix)
        }
    }

    private func replaceFile(at path: String) throws {
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }
}
