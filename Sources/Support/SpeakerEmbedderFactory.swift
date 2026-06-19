// SpeakerEmbedderFactory.swift
// App-layer resolution of the optional speaker-embedding model. Keeps Bundle.main
// / filesystem lookups out of TranscriptedCore (which stays injection-only) and
// hands the meeting controller a ready `SpeakerSegmentEmbedder` or nil.

import Foundation
import TranscriptedCore

enum SpeakerEmbedderFactory {

    /// Directory name as bundled into the app Resources (see build.sh) and the
    /// compiled model file inside it.
    private static let bundleDirName = "eres2net-embedding"
    private static let modelFileName = "Model.mlmodelc"

    /// Build the segment embedder for `choice`, or nil to use the diarizer's
    /// native WeSpeaker embedding. Returns nil (falling back to WeSpeaker) if the
    /// ERes2Net model can't be located or loaded.
    static func makeEmbedder(for choice: SpeakerEmbedderChoice) -> (any SpeakerSegmentEmbedder)? {
        guard choice == .eRes2Net else { return nil }
        guard #available(macOS 14.0, *) else { return nil }
        guard let url = resolveModelURL() else {
            AppLog.speakerEmbedder("ERes2Net model not found in bundle or cache; using WeSpeaker")
            return nil
        }
        guard let embedder = ERes2NetEmbedder(modelURL: url) else {
            AppLog.speakerEmbedder("ERes2Net model failed to load at \(url.lastPathComponent); using WeSpeaker")
            return nil
        }
        AppLog.speakerEmbedder("ERes2Net speaker embedder active (dim \(embedder.dimension))")
        return embedder
    }

    /// Speaker DB path for the *active* embedding model. ERes2Net (192-dim) uses a
    /// separate file so its vectors never share a `SpeakerProfile` row with the
    /// WeSpeaker (256-dim) defaults. Falls back to the default `speakers.sqlite`
    /// when ERes2Net isn't selected or its model isn't on disk. Kept here (not in
    /// MeetingStoragePaths) so the low-level storage-paths file stays dependency-free.
    static func activeSpeakerDBURL() -> URL {
        let state = FileManager.default.transcriptedStateDir
        let useERes2Net = SpeakerEmbedderPreferences.effectiveChoice() == .eRes2Net
            && resolveModelURL() != nil
        let name = useERes2Net ? "speakers_eres2net.sqlite" : "speakers.sqlite"
        return state.appendingPathComponent(name, isDirectory: false)
    }

    /// First match wins: app bundle Resources, then the shared FluidAudio Models
    /// cache (where build.sh sources it from and where dev builds stage it).
    static func resolveModelURL() -> URL? {
        var candidates: [URL] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append(URL(fileURLWithPath: resourcePath)
                .appendingPathComponent(bundleDirName)
                .appendingPathComponent(modelFileName))
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport
                .appendingPathComponent("FluidAudio/Models")
                .appendingPathComponent(bundleDirName)
                .appendingPathComponent(modelFileName))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Tiny logging shim so this file does not depend on a specific AppLogger surface.
private enum AppLog {
    static func speakerEmbedder(_ message: String) {
        NSLog("[SpeakerEmbedder] %@", message)
    }
}
