// SpeakerEmbedderFactory.swift
// App-layer resolution of the optional speaker-embedding model. Keeps Bundle.main
// / filesystem lookups out of TranscriptedCore (which stays injection-only) and
// hands the meeting controller a `SpeakerSegmentEmbedder` or nil.
//
// Nothing here loads a model. The meeting controller is built on the main actor at
// launch, and `MLModel(contentsOf:)` (plus a GPU compile the first launch after an
// update) froze the menubar there. The choice, and with it the speaker database, is
// made from model-file presence; the model loads on a background queue the first
// time the diarizer's warmup, a meeting, or the voiceprint migration waits for it
// (`BackgroundLoadedSpeakerSegmentEmbedder`).

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

    /// One resolution per model per process: the meeting controller and the
    /// Settings DB-path lookup share it, so the model loads once and both agree on
    /// the database for the whole launch, even after a failed load. ReDimNet2's
    /// idle release frees the GPU memory between meetings.
    private static let resolutionLock = NSLock()
    nonisolated(unsafe) private static var resolvedEmbedders: [SpeakerEmbedderChoice: (any SpeakerSegmentEmbedder)?] = [:]

    /// The segment embedder for `choice`, or nil to use the diarizer's native
    /// WeSpeaker embedding (and the default `speakers.sqlite`). Never loads the
    /// model: returns a background-loading embedder when the model file is present
    /// and the model hasn't failed to load on this build, else nil. A load that
    /// fails later leaves this launch on the chosen model's database with no
    /// voiceprints and makes the next launch return nil
    /// (`SpeakerEmbedderLoadFailureMemory`).
    static func makeEmbedder(for choice: SpeakerEmbedderChoice) -> (any SpeakerSegmentEmbedder)? {
        guard #available(macOS 14.0, *) else { return nil }
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        if let resolved = resolvedEmbedders[choice] { return resolved }
        let embedder: (any SpeakerSegmentEmbedder)?
        switch choice {
        case .weSpeaker:
            embedder = nil
        case .reDimNet2:
            embedder = backgroundEmbedder(
                name: "ReDimNet2",
                modelURL: reDimNet2ModelURL(),
                configuration: ReDimNet2Embedder.configuration(modelURL:),
                load: { ReDimNet2Embedder.load(modelURL: $0) }
            )
        case .eRes2Net:
            embedder = backgroundEmbedder(
                name: "ERes2Net",
                modelURL: resolveModelURL(),
                configuration: ERes2NetEmbedder.configuration(modelURL:),
                load: { ERes2NetEmbedder(modelURL: $0) }
            )
        }
        resolvedEmbedders[choice] = .some(embedder)
        return embedder
    }

    /// A background-loading embedder for the model at `modelURL`, or nil (WeSpeaker)
    /// when the file is missing or the model failed to load on this build.
    @available(macOS 14.0, *)
    private static func backgroundEmbedder(
        name: String,
        modelURL: URL?,
        configuration: (URL) -> CoreMLSpeakerEmbedderConfiguration,
        failureMemory: SpeakerEmbedderLoadFailureMemory = SpeakerEmbedderLoadFailureMemory(),
        load: @escaping @Sendable (URL) -> (any SpeakerSegmentEmbedder)?
    ) -> (any SpeakerSegmentEmbedder)? {
        guard let modelURL else {
            AppLog.speakerEmbedder("\(name) model not found in bundle or cache; using WeSpeaker")
            return nil
        }
        let declared = configuration(modelURL)
        guard failureMemory.launchModelIdentifier(chosen: declared.identifier, modelFileIsPresent: true) != nil else {
            AppLog.speakerEmbedder("\(name) model failed to load on this build; using WeSpeaker")
            return nil
        }
        let identifier = declared.identifier
        let dimension = declared.dimension
        return BackgroundLoadedSpeakerSegmentEmbedder(
            identifier: identifier,
            dimension: dimension,
            thresholds: declared.thresholds,
            onLoadEnded: { loaded in
                failureMemory.recordLoadEnded(identifier, loaded: loaded)
                AppLog.speakerEmbedder(loaded
                    ? "\(name) speaker embedder loaded (dim \(dimension))"
                    : "\(name) model failed to load; no voiceprints this launch, WeSpeaker from the next")
            },
            load: { load(modelURL) }
        )
    }

    /// Speaker DB path that matches a *resolved* embedder (`makeEmbedder`). A
    /// 192-dim model gets its own file, named from the embedder's identifier; a nil
    /// embedder (WeSpeaker, or a chosen model that is missing or failed to load on
    /// this build) uses the default `speakers.sqlite`. A DB never receives a vector
    /// of the wrong dimension: a background load that fails after launch makes the
    /// embedder return no vectors, rather than routing 256-d WeSpeaker vectors into
    /// a 192-d database. Kept here (not in MeetingStoragePaths) so the low-level
    /// storage-paths file stays dependency-free.
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
        let name = SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: identifier)
        return state.appendingPathComponent(name, isDirectory: false)
    }

    /// DB path for the active selection where the embedder isn't already in hand
    /// (e.g. the Settings → People fallback). Shares `makeEmbedder`'s resolution, so
    /// the path agrees with what the meeting pipeline uses, without loading a model.
    static func activeSpeakerDBURL() -> URL {
        speakerDBURL(
            for: makeEmbedder(for: SpeakerEmbedderChoiceResolution.effectiveChoice()),
            diarizationBackend: activeDiarizationBackend()
        )
    }

    /// Core's backend for the hidden diarization switch. Same rule `import-audio`
    /// uses (`DiarizationBackend.effective`): env, then the stored preference,
    /// then Nemotron.
    static func activeDiarizationBackend() -> DiarizationBackend {
        DiarizationBackend.effective(
            storedPreference: UserDefaults.standard.string(forKey: DiarizationBackend.preferenceKey),
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// The ReDimNet2 model's location, without loading it (Settings uses this to
    /// tell whether the build has the model).
    static func reDimNet2ModelURL() -> URL? {
        resolveModelURL(bundleDirName: reDimNet2BundleDirName, cacheDirName: reDimNet2CacheDirName)
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
