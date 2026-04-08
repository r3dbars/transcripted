// DraftPaths.swift
// Shared Application Support directory helper — safe fallback, no force-unwraps.

import Foundation

extension FileManager {
    /// Prefer the legacy Draft-named folder when it already exists so upgrades keep
    /// seeing the same on-disk data. Fresh installs use ~/Library/Application Support/Transcripted/.
    var transcriptedAppSupportDir: URL {
        let appSupport = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let transcriptedDir = appSupport.appendingPathComponent("Transcripted", isDirectory: true)
        let legacyDraftDir = appSupport.appendingPathComponent("Draft", isDirectory: true)

        if fileExists(atPath: legacyDraftDir.path) {
            return legacyDraftDir
        }

        return transcriptedDir
    }

    /// Compatibility alias while the rest of the app finishes renaming internals.
    var draftAppSupportDir: URL {
        transcriptedAppSupportDir
    }

    /// ~/Library/Application Support/{Draft|Transcripted}/meetings/
    var meetingSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("meetings", isDirectory: true)
    }

    /// ~/Library/Application Support/{Draft|Transcripted}/dictations/
    var dictationSupportDir: URL {
        transcriptedAppSupportDir.appendingPathComponent("dictations", isDirectory: true)
    }
}
