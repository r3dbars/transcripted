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
