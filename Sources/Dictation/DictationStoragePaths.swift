// DictationStoragePaths.swift
// Draft-backed storage layout for dictation markdown exports.

import Foundation

enum DictationStoragePaths {
    /// Root: ~/Library/Application Support/Draft/dictations/
    static var root: URL {
        let url = FileManager.default.dictationSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Folder for saved markdown exports.
    static var transcriptsFolder: URL {
        let url = root.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
