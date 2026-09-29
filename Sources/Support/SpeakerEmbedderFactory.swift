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

    /// ReDimNet2 model directory in the app Resources (see build.sh) and in the
    /// shared FluidAudio Models cache, where dev builds and build.sh source it
    /// (scripts/models/redimnet2/install.sh puts it there).
    private static let reDimNet2BundleDirName = "redimnet2-voiceprint"
    private static let reDimNet2CacheDirName = "redimnet2-b4-slim"

    /// One ReDimNet2 instance per process: the meeting controller and the Settings
    /// DB-path lookup share it, so the model loads once. Its idle release frees the
    /// GPU memory between meetings.
    private static let reDimNet2Lock = NSLock()
    nonisolated(unsafe) private static var reDimNet2Resolved = false
    nonisolated(unsafe) private static var reDimNet2Embedder: (any SpeakerSegmentEmbedder)?

    /// Build the segment embedder for `choice`, or nil to use the diarizer's
    /// native WeSpeaker embedding. Returns nil (falling back to WeSpeaker, and the
    /// default `speakers.sqlite`) if the chosen model can't be located or loaded.
    static func makeEmbedder(for choice: SpeakerEmbedderChoice) -> (any SpeakerSegmentEmbedder)? {
        guard #available(macOS 14.0, *) else { return nil }
        switch choice {
        case .weSpeaker:
            return nil
        case .reDimNet2:
            return sharedReDimNet2()
        case .eRes2Net:
            break
        }
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

    /// Speaker DB path that matches a *resolved* embedder. ERes2Net (192-dim) gets
    /// its own file, named from the embedder's identifier; a nil embedder (WeSpeaker,
    /// or an ERes2Net model that could not be loaded) uses the default
    /// `speakers.sqlite`. Deriving the path from the embedder that actually loaded —
    /// not from mere model-file existence — guarantees a DB never receives a vector
    /// of the wrong dimension (e.g. a present-but-unloadable model must NOT route
    /// 256-d WeSpeaker vectors into the 192-d ERes2Net database). Kept here (not in
    /// MeetingStoragePaths) so the low-level storage-paths file stays dependency-free.
    ///
    /// The Nemotron diarization backend has no voiceprints of its own. With no
    /// injected embedder, Core fills them with the pyannote pipeline's own offline
    /// WeSpeaker model (`FluidOfflineWeSpeakerSegmentEmbedder`), the model every person
    /// in `speakers.sqlite` was learned from, so Nemotron shares that database. The
    /// YODAS3 speaker lab measured speaker-level cosine 0.986-0.995 against the
    /// pyannote vectors on the same audio. Only the lab-only
    /// `TRANSCRIPTED_NEMOTRON_EMBEDDER=online` override (FluidAudio's online WeSpeaker
    /// conversion, a nearby but different space) gets its own database.
    static func speakerDBURL(
        for embedder: (any SpeakerSegmentEmbedder)?,
        diarizationBackend: DiarizationBackend = .pyannote,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let state = FileManager.default.transcriptedStateDir
        let onlineNemotronVoiceprints = diarizationBackend == .nemotron
            && environment["TRANSCRIPTED_NEMOTRON_EMBEDDER"] == "online"
        let identifier = embedder?.identifier
            ?? (onlineNemotronVoiceprints ? FluidWeSpeakerSegmentEmbedder.embedderIdentifier : nil)
        let name = SpeakerEmbedderPreferences.speakerDBFileName(forEmbedderIdentifier: identifier)
        return state.appendingPathComponent(name, isDirectory: false)
    }

    /// DB path for the active selection where the embedder isn't already in hand
    /// (e.g. the Settings → People fallback). Resolves the embedder by actually
    /// loading it so the path agrees with what the meeting pipeline will use.
    static func activeSpeakerDBURL() -> URL {
        speakerDBURL(
            for: makeEmbedder(for: SpeakerEmbedderPreferences.effectiveChoice()),
            diarizationBackend: activeDiarizationBackend()
        )
    }

    /// Core's backend for the hidden diarization switch (see DiarizationBackendPreferences).
    static func activeDiarizationBackend() -> DiarizationBackend {
        switch DiarizationBackendPreferences.effectiveChoice() {
        case .pyannote: return .pyannote
        case .nemotron: return .nemotron
        }
    }

    /// The ReDimNet2 model's location, without loading it (Settings uses this to
    /// tell whether the build has the model).
    static func reDimNet2ModelURL() -> URL? {
        resolveModelURL(bundleDirName: reDimNet2BundleDirName, cacheDirName: reDimNet2CacheDirName)
    }

    @available(macOS 14.0, *)
    private static func sharedReDimNet2() -> (any SpeakerSegmentEmbedder)? {
        reDimNet2Lock.lock()
        defer { reDimNet2Lock.unlock() }
        if reDimNet2Resolved { return reDimNet2Embedder }
        reDimNet2Resolved = true
        guard let url = reDimNet2ModelURL() else {
            AppLog.speakerEmbedder("ReDimNet2 model not found in bundle or cache; using WeSpeaker")
            return nil
        }
        guard let embedder = ReDimNet2Embedder.load(modelURL: url) else {
            AppLog.speakerEmbedder("ReDimNet2 model failed to load; using WeSpeaker")
            return nil
        }
        AppLog.speakerEmbedder("ReDimNet2 speaker embedder active (dim \(embedder.dimension))")
        reDimNet2Embedder = embedder
        return embedder
    }

    /// First match wins: app bundle Resources, then the shared FluidAudio Models
    /// cache (where build.sh sources it from and where dev builds stage it).
    static func resolveModelURL() -> URL? {
        resolveModelURL(bundleDirName: bundleDirName, cacheDirName: bundleDirName)
    }

    /// First match wins: `Resources/<bundleDirName>/Model.mlmodelc`, then
    /// `FluidAudio/Models/<cacheDirName>/Model.mlmodelc` in Application Support.
    static func resolveModelURL(bundleDirName: String, cacheDirName: String) -> URL? {
        var candidates: [URL] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append(URL(fileURLWithPath: resourcePath)
                .appendingPathComponent(bundleDirName)
                .appendingPathComponent(modelFileName))
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport
                .appendingPathComponent("FluidAudio/Models")
                .appendingPathComponent(cacheDirName)
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
