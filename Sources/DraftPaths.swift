// DraftPaths.swift
// Shared Application Support directory helper — safe fallback, no force-unwraps.

import Foundation

extension FileManager {
    /// Transcripted-facing compatibility helper.
    /// Current main still keeps app-support data under Draft's existing folder
    /// until a deliberate migration path exists.
    var transcriptedAppSupportDir: URL {
        let appSupport = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Draft", isDirectory: true)
    }

    /// Legacy alias while older code still refers to the Draft-named root.
    var draftAppSupportDir: URL {
        transcriptedAppSupportDir
    }

    /// ~/Library/Application Support/Draft/meetings/
    var meetingSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("meetings", isDirectory: true)
    }

    /// ~/Library/Application Support/Draft/dictations/
    var dictationSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("dictations", isDirectory: true)
    }
}
