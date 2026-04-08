// DraftPaths.swift
// Shared Application Support directory helper — safe fallback, no force-unwraps.

import Foundation

extension FileManager {
    /// ~/Library/Application Support/Transcripted/ — safe fallback if system API returns empty.
    var transcriptedAppSupportDir: URL {
        let appSupport = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Transcripted", isDirectory: true)
    }

    /// Compatibility alias while the rest of the app finishes renaming internals.
    var draftAppSupportDir: URL {
        transcriptedAppSupportDir
    }

    /// ~/Library/Application Support/Transcripted/meetings/
    var meetingSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("meetings", isDirectory: true)
    }

    /// ~/Library/Application Support/Transcripted/dictations/
    var dictationSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("dictations", isDirectory: true)
    }
}
