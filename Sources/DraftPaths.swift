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

    /// ~/Library/Application Support/Draft/meetings/ — isolated from Transcripted's ~/Documents/Transcripted
    /// so the two apps can coexist on one machine without touching each other's transcripts,
    /// speakers DB, stats, or failed-transcription queue. See merge-plan.md §6.5 Option B.
    var meetingSupportDir: URL {
        draftAppSupportDir.appendingPathComponent("meetings", isDirectory: true)
    }
}
