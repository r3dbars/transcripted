// DraftPaths.swift
// Shared Application Support directory helper — safe fallback, no force-unwraps.

import Foundation

extension FileManager {
    /// ~/Library/Application Support/Draft/ — safe fallback if system API returns empty.
    var draftAppSupportDir: URL {
        let appSupport = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Draft", isDirectory: true)
    }
}
