// DictationStoragePaths.swift
// Capture-library-backed storage layout for dictation markdown exports.

import Foundation

enum DictationStoragePaths {
    /// Root: <capture-library>/dictations/
    static var root: URL {
        let url = FileManager.default.dictationSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dictation captures live directly in the dictations folder.
    static var transcriptsFolder: URL {
        root
    }
}
