// DiarizationBackend.swift
// Which speaker-diarization model `DiarizationService` runs. Pure value type with
// no FluidAudio dependency so hosts, settings, and the speaker lab can name a
// backend without importing the model stack.

import Foundation

/// Which speaker-diarization model splits meeting audio into speaker turns.
public enum DiarizationBackend: String, CaseIterable, Sendable, Codable {
    /// FluidAudio's offline pyannote community-1 pipeline (segmentation +
    /// WeSpeaker + VBx). The Core default and Nemotron's load fallback; emits a
    /// native 256-d WeSpeaker embedding per segment.
    case pyannote
    /// NVIDIA Nemotron 3 Diarization via FluidAudio (streaming Sortformer
    /// successor, up to 8 speakers, 10 ms frames). The app's default. It emits no speaker embeddings, so `DiarizationService` derives
    /// one per turn with the injected `SpeakerSegmentEmbedder`, or with
    /// `FluidWeSpeakerSegmentEmbedder` when none is injected.
    case nemotron
}

extension DiarizationBackend {
    /// Host default for the app and `import-audio`. `DiarizationService`'s init
    /// stays `.pyannote` so library callers keep the old default; hosts opt in.
    public static let hostDefault: DiarizationBackend = .nemotron
    /// Stored in the app's defaults domain (`SpeakerVoiceprintSelection.appDefaultsDomain`).
    public static let preferenceKey = "diarization-backend-preference"
    /// Dev/lab override. Wins over the stored preference.
    public static let environmentKey = "TRANSCRIPTED_DIARIZATION_BACKEND"
    /// Nemotron feed-slice length in seconds. The runner appends
    /// `nemotronSliceSamples` (16 kHz); CLI window counts use the same value
    /// so they cannot drift from a second hard-coded 10.
    public static let nemotronSliceSeconds: Double = 10
    public static var nemotronSliceSamples: Int {
        Int((nemotronSliceSeconds * 16_000).rounded())
    }
    /// FluidAudio `ModelNames.Nemotron3.weightsVersion`. A HuggingFace cache
    /// without this exact marker is deleted and re-downloaded.
    public static let nemotronCacheMarkerName = ".fluidaudio-nemotron3-weights"
    public static let nemotronCacheWeightsVersion = "ga-2026-09-23"
    public static let nemotronCacheSilenceName = "learnable_sil_emb.bin"

    /// HuggingFace / FluidAudio file for this preset. Split-graph names are
    /// not `Nemotron3Diarizer_<preset>`: hyphens become underscores, and
    /// `fast32-split*` is published as `s32_split*`.
    public static func nemotronModelFileName(preset: String) -> String {
        switch preset {
        case "c128-split-w8a8":
            return "Nemotron3Diarizer_c128_split_w8a8.mlmodelc"
        case "fast32-split-w8a8":
            return "Nemotron3Diarizer_s32_split_w8a8.mlmodelc"
        case "c128-split":
            return "Nemotron3Diarizer_c128_split.mlmodelc"
        case "fast32-split":
            return "Nemotron3Diarizer_s32_split.mlmodelc"
        default:
            return "Nemotron3Diarizer_\(preset).mlmodelc"
        }
    }

    /// Split-graph presets (`c128-split-w8a8`, `fast32-split-w8a8`) live under
    /// `split/` and need the host-side projection file.
    public static let nemotronProjectionFileName = "pre_encode_proj_t.bin"

    public static func nemotronPresetIsSplit(_ preset: String) -> Bool {
        preset.contains("split")
    }

    public static func nemotronCacheModelSubpaths(preset: String) -> [String] {
        let file = nemotronModelFileName(preset: preset)
        if nemotronPresetIsSplit(preset) {
            return ["split/\(file)", "split/v2/\(file)", file]
        }
        return ["monolithic/v2/\(file)", "monolithic/\(file)", file]
    }

    public static func nemotronRequiredCompanionFiles(preset: String) -> [String] {
        var files = [nemotronCacheSilenceName]
        if nemotronPresetIsSplit(preset) {
            files.append(nemotronProjectionFileName)
        }
        return files
    }

    /// Roots FluidAudio may put companion files next to, under, or above the model.
    public static let nemotronCompanionSearchRoots = [
        "", "monolithic/", "monolithic/v2/", "split/", "split/v2/"
    ]

    /// Model + companion URLs for a local load (`Nemotron3Models.load`), never
    /// HuggingFace. Flat bundle first, then the provisioned cache layout.
    public static func nemotronLocalLoadFiles(
        in directory: URL,
        preset: String
    ) -> (model: URL, companions: [URL])? {
        let fm = FileManager.default
        let modelName = nemotronModelFileName(preset: preset)
        let companionNames = nemotronRequiredCompanionFiles(preset: preset)
        let flatModel = directory.appendingPathComponent(modelName)
        let flatCompanions = companionNames.map { directory.appendingPathComponent($0) }
        if fm.fileExists(atPath: flatModel.path),
           flatCompanions.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
            return (flatModel, flatCompanions)
        }
        guard let modelRel = nemotronCacheModelSubpaths(preset: preset).first(where: {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else {
            return nil
        }
        var companions: [URL] = []
        companions.reserveCapacity(companionNames.count)
        for name in companionNames {
            guard let found = nemotronCompanionSearchRoots
                .map({ directory.appendingPathComponent("\($0)\(name)") })
                .first(where: { fm.fileExists(atPath: $0.path) })
            else {
                return nil
            }
            companions.append(found)
        }
        return (directory.appendingPathComponent(modelRel), companions)
    }

    /// Marker file contents FluidAudio will accept (`weightsVersion` plus optional newline).
    public static func nemotronCacheHasMatchingMarker(contents: String?) -> Bool {
        guard let contents else { return false }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == nemotronCacheWeightsVersion
    }

    /// The stored choice, ignoring the environment. Unknown or missing values
    /// read as the host default.
    public static func preferred(storedPreference: String?) -> DiarizationBackend {
        guard let raw = storedPreference?.lowercased(),
              let backend = DiarizationBackend(rawValue: raw) else {
            return hostDefault
        }
        return backend
    }

    /// The engine a host should run: a valid environment override first (any
    /// case), then the stored preference, then `hostDefault`.
    public static func effective(
        storedPreference: String?,
        environment: [String: String]
    ) -> DiarizationBackend {
        if let raw = environment[environmentKey]?.lowercased(),
           let backend = DiarizationBackend(rawValue: raw) {
            return backend
        }
        return preferred(storedPreference: storedPreference)
    }

    /// The `diarization_engine` frontmatter value for a meeting this backend
    /// diarized. `pyannote_offline` predates the switch, so it stays as is.
    public var transcriptEngineIdentifier: String {
        switch self {
        case .pyannote: return "pyannote_offline"
        case .nemotron: return "nemotron_offline"
        }
    }

    /// Name for the raw transcript footer. `PyAnnote` keeps the footer older
    /// files carry; the frontmatter key is the one to read for model identity.
    public var footerDisplayName: String {
        switch self {
        case .pyannote: return "PyAnnote"
        case .nemotron: return "Nemotron"
        }
    }
}

/// What actually diarized one meeting: the backend that ran (a Nemotron load
/// failure reads `.pyannote`) and the voiceprint model that embedded its turns.
/// The pipeline takes it from the diarizer right before diarizing, and the
/// transcript writes it as `diarization_engine` / `voiceprint_model`.
public struct DiarizationRunDescriptor: Sendable, Equatable {
    public let backend: DiarizationBackend
    /// The embedder's identifier (e.g. `redimnet2-b4`, `wespeaker`), or nil
    /// when the engine doesn't say.
    public let voiceprintModel: String?

    public init(backend: DiarizationBackend, voiceprintModel: String?) {
        self.backend = backend
        self.voiceprintModel = voiceprintModel
    }
}
