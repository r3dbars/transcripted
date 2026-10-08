#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import ArgumentParser
import Foundation
import TranscriptedCore

/// Which voiceprint model import-audio uses and which saved-speaker database goes
/// with it. `--speaker-embedder app` (the default) follows Core's
/// `SpeakerVoiceprintSelection`, the same rule the app uses: the app's stored
/// preference or `TRANSCRIPTED_SPEAKER_EMBEDDER`, ReDimNet2 by default, and
/// WeSpeaker with `speakers.sqlite` when the chosen model is missing or failed to
/// load on this app build. An explicit model never falls back silently.
struct MeetingImportVoiceprint {
    typealias Model = SpeakerVoiceprintSelection.Model

    let model: Model
    /// nil means WeSpeaker (the diarizer's own voiceprint).
    let embedder: (any SpeakerSegmentEmbedder)?
    let databaseURL: URL
    /// The fallback note, when the chosen model couldn't be used.
    let note: String?

    var thresholds: SpeakerEmbeddingThresholds { embedder?.thresholds ?? .weSpeaker }
    /// Vector size this run produces (WeSpeaker's is 256).
    var dimension: Int { embedder?.dimension ?? Self.weSpeakerDimension }
    static let weSpeakerDimension = 256

    /// A description of the stored vectors' size when no saved person matches this
    /// model's, e.g. "256-dimension"; nil when they match or the database is empty.
    static func dimensionMismatch(profiles: [SpeakerProfile], voiceprint: MeetingImportVoiceprint) -> String? {
        let sizes = Set(profiles.map(\.embedding.count).filter { $0 > 0 })
        guard !sizes.isEmpty, !sizes.contains(voiceprint.dimension) else { return nil }
        return sizes.sorted().map { "\($0)-dimension" }.joined(separator: "/")
    }
    var modelName: String { Self.displayName(embedder == nil ? .weSpeaker : model) }
    var summary: String { modelName + (note.map { " (\($0))" } ?? "") }

    static func displayName(_ model: Model) -> String {
        switch model {
        case .weSpeaker: return "WeSpeaker"
        case .eRes2Net: return "ERes2Net"
        case .reDimNet2: return "ReDimNet2"
        }
    }

    /// Reason every speaker stays numbered when the database file is missing.
    func missingDatabaseReason(fileManager: FileManager = .default) -> String {
        let legacy = databaseURL.deletingLastPathComponent().appendingPathComponent("speakers.sqlite")
        if embedder != nil, fileManager.fileExists(atPath: legacy.path) {
            return "there's no \(modelName) speaker database yet; open Transcripted once so it can carry your saved people over"
        }
        return "there's no saved speaker database for \(modelName)"
    }
}

/// The decision before any model loads, so tests can check it without Core ML.
struct MeetingImportVoiceprintPlan: Equatable {
    let model: SpeakerVoiceprintSelection.Model
    let explicit: Bool
    let modelURL: URL?
    let resolution: SpeakerVoiceprintSelection.Resolution
    let databaseURL: URL
}

extension MeetingImportModels {
    static func voiceprintModelURLs(
        for model: SpeakerVoiceprintSelection.Model,
        resourceDirectories: [URL],
        homeDirectory: URL
    ) -> [URL] {
        let names: (bundle: String, cache: String)
        switch model {
        case .weSpeaker: return []
        case .eRes2Net: names = ("eres2net-embedding", "eres2net-embedding")
        case .reDimNet2: names = ("redimnet2-voiceprint", "redimnet2-b4-slim")
        }
        // Same places the app looks (SpeakerEmbedderFactory): app Resources, then
        // the shared FluidAudio cache.
        return resourceDirectories.map {
            $0.appendingPathComponent(names.bundle).appendingPathComponent("Model.mlmodelc")
        } + [homeDirectory
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            .appendingPathComponent(names.cache)
            .appendingPathComponent("Model.mlmodelc")]
    }

    /// The app's state folder, where speaker databases live. Follows the app's
    /// `TRANSCRIPTED_CONTAINER_DIR` override (an absolute path), like the app.
    static func appStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment["TRANSCRIPTED_CONTAINER_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
                .appendingPathComponent("state", isDirectory: true)
        }
        return CoreStoragePaths.default.speakerDB.deletingLastPathComponent()
    }

    /// The containing (or installed) app's build key, for the app's per-build
    /// voiceprint load-failure memory. nil when no app Info.plist is found.
    static func appBuildKey(resourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories()) -> String? {
        for resources in resourceDirectories {
            let plist = resources.deletingLastPathComponent().appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: plist),
                  let version = info["CFBundleVersion"] as? String else { continue }
            return SpeakerVoiceprintSelection.buildKey(
                bundleVersion: version,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
        }
        return nil
    }

    static func voiceprintPlan(
        choice: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(forName: SpeakerVoiceprintSelection.appDefaultsDomain),
        resourceDirectories: [URL] = CLIModelPaths.bundledResourceDirectories(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stateDirectory: URL? = nil,
        appBuildKey: String?? = nil
    ) -> MeetingImportVoiceprintPlan {
        let explicit = choice != "app"
        let model = explicit
            ? (SpeakerVoiceprintSelection.Model(rawValue: choice) ?? .weSpeaker)
            : SpeakerVoiceprintSelection.effectiveModel(
                storedPreference: appDefaults?[SpeakerVoiceprintSelection.preferenceKey] as? String,
                environment: environment
            )
        let modelURL = voiceprintModelURLs(for: model, resourceDirectories: resourceDirectories, homeDirectory: homeDirectory)
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let buildKey = appBuildKey ?? self.appBuildKey(resourceDirectories: resourceDirectories)
        let failures = appDefaults?[SpeakerVoiceprintSelection.loadFailuresKey] as? [String: String] ?? [:]
        let resolution = SpeakerVoiceprintSelection.resolve(
            chosen: model,
            modelFileIsPresent: { $0 == model && modelURL != nil },
            // An explicit choice always tries the model; the app's failure memory
            // only steers the default, as it does in the app.
            failedOnThisBuild: { identifier in
                guard !explicit, let buildKey else { return false }
                return SpeakerVoiceprintSelection.failedOnThisBuild(identifier, recordedFailures: failures, buildKey: buildKey)
            }
        )
        let state = stateDirectory ?? appStateDirectory(environment: environment)
        return MeetingImportVoiceprintPlan(
            model: model, explicit: explicit, modelURL: modelURL, resolution: resolution,
            databaseURL: state.appendingPathComponent(resolution.databaseFileName)
        )
    }

    static func voiceprint(
        choice: String,
        plan: MeetingImportVoiceprintPlan? = nil,
        load: (SpeakerVoiceprintSelection.Model, URL) -> (any SpeakerSegmentEmbedder)? = loadEmbedder
    ) throws -> MeetingImportVoiceprint {
        let plan = plan ?? voiceprintPlan(choice: choice)
        let name = MeetingImportVoiceprint.displayName(plan.model)
        let wespeakerDB = plan.databaseURL.deletingLastPathComponent().appendingPathComponent(
            SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: nil))
        guard plan.model != .weSpeaker else {
            return MeetingImportVoiceprint(model: .weSpeaker, embedder: nil, databaseURL: plan.databaseURL,
                                           note: plan.explicit ? "selected with --speaker-embedder" : "the app's setting")
        }
        if plan.explicit, plan.modelURL == nil {
            throw ValidationError("\(name) was selected but its local model isn't installed. Install it in Transcripted, or pick another --speaker-embedder.")
        }
        guard plan.resolution.embedderIdentifier != nil, let modelURL = plan.modelURL else {
            let why = plan.resolution.fallback == .failedToLoadOnThisBuild
                ? "failed to load in this app build" : "isn't installed"
            MeetingImportWorkflow.log("Warning: the app's \(name) voiceprint model \(why); using WeSpeaker and its separate speaker database, as the app does.")
            return MeetingImportVoiceprint(model: plan.model, embedder: nil, databaseURL: wespeakerDB,
                                           note: "fallback: \(name) \(why)")
        }
        guard let embedder = load(plan.model, modelURL) else {
            if plan.explicit {
                throw ValidationError("\(name) was selected but its local model could not load. Pick another --speaker-embedder.")
            }
            MeetingImportWorkflow.log("Warning: the \(name) voiceprint model could not load; using WeSpeaker and its separate speaker database, as the app's next launch would.")
            return MeetingImportVoiceprint(model: plan.model, embedder: nil, databaseURL: wespeakerDB,
                                           note: "fallback: \(name) could not load")
        }
        return MeetingImportVoiceprint(model: plan.model, embedder: embedder, databaseURL: plan.databaseURL,
                                       note: plan.explicit ? "selected with --speaker-embedder" : "the app's setting")
    }

    static func loadEmbedder(_ model: SpeakerVoiceprintSelection.Model, _ url: URL) -> (any SpeakerSegmentEmbedder)? {
        switch model {
        case .weSpeaker: return nil
        case .eRes2Net: return ERes2NetEmbedder(modelURL: url)
        case .reDimNet2: return ReDimNet2Embedder.load(modelURL: url)
        }
    }
}
#endif
