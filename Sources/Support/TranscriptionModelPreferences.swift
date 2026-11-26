import Foundation

/// App-owned model identity; conversion to FluidAudio stays at the Speech boundary.
enum ParakeetModelVariant: String, CaseIterable, Sendable {
    case v3
    /// Moondream's Parakeet Ultra: a retrained parakeet-tdt-0.6b-v3 with the
    /// same architecture and tokenizer, so FluidAudio loads it as v3. There is
    /// no hosted Core ML build, so it is never downloaded or bundled; it only
    /// exists once scripts/models/parakeet-ultra has converted and installed it.
    case ultra

    /// Marker the Ultra install script writes last. It sits inside the folder
    /// FluidAudio loads, so a FluidAudio "delete and re-download v3" recovery
    /// removes it, and a folder without it is never treated as Ultra.
    static let localInstallMarkerFileName = "transcripted-model.json"

    var directoryName: String { "parakeet-tdt-0.6b-\(rawValue)" }
    var jointModelName: String { "JointDecisionv3.mlmodelc" }
    var requiredModelDirectoryNames: [String] {
        ["Encoder.mlmodelc", jointModelName, "Decoder.mlmodelc", "Preprocessor.mlmodelc"]
    }
    var requiredFileNames: [String] {
        // FluidAudio v0.17.0: ModelNames.swift and AsrModels.getRequiredModels
        // define the compiled model set. Recheck this contract when changing
        // the dependency version.
        switch self {
        case .v3:
            return ["config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"]
        case .ultra:
            return ["config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json", Self.localInstallMarkerFileName]
        }
    }

    /// Experimental models installed by a local script: never downloaded
    /// (FluidAudio would fetch stock v3 instead) and never bundled.
    var isLocalInstallOnly: Bool { self == .ultra }

    /// Where a local-install-only model lives under Transcripted's models
    /// folder. FluidAudio's AsrModels.load(from:) resolves
    /// `<parent>/parakeet-tdt-0.6b-v3`, so the leaf keeps the v3 folder name
    /// and the parent folder carries the identity.
    var localInstallRelativePath: String? {
        switch self {
        case .v3: return nil
        case .ultra: return "parakeet-ultra/parakeet-tdt-0.6b-v3"
        }
    }
}

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetTDTv3 = "parakeet-tdt-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case parakeetUltraExperimental = "parakeet-ultra-experimental"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet TDT V3"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .parakeetUltraExperimental:
            return "Parakeet Ultra (Experimental)"
        }
    }

    var shortTitle: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet V3"
        case .whisperLargeV3Turbo:
            return "Whisper Turbo"
        case .parakeetUltraExperimental:
            return "Parakeet Ultra"
        }
    }

    var summary: String {
        switch self {
        case .parakeetTDTv3:
            return "Default multilingual local model for dictation and meetings."
        case .whisperLargeV3Turbo:
            return "Local Whisper with broad language coverage."
        case .parakeetUltraExperimental:
            // CC-BY-4.0 attribution for Moondream's weights.
            return "Experimental. Moondream's retrained Parakeet V3 (Parakeet Ultra, CC-BY-4.0), converted to run on this Mac."
        }
    }

    var isWhisper: Bool {
        switch self {
        case .parakeetTDTv3, .parakeetUltraExperimental:
            return false
        case .whisperLargeV3Turbo:
            return true
        }
    }

    /// Whisper can transcribe a meeting in a chosen language;
    /// Parakeet is always automatic.
    var supportsMeetingLanguageChoice: Bool {
        isWhisper
    }

    var engineName: String {
        switch self {
        case .parakeetTDTv3, .parakeetUltraExperimental:
            return "parakeet"
        case .whisperLargeV3Turbo:
            return "whisper"
        }
    }

    /// Historical engine identifiers from retired models so older saved
    /// transcripts still show the model that made them.
    private static let legacyEngineShortTitles: [String: String] = [
        "parakeet_v2_local": "Parakeet V2",
        "whisper_large_v3_local": "Whisper",
        "apple_speech_local": "Apple Speech",
    ]

    /// Short model name for a saved transcript's `transcription_engine` id,
    /// or nil for an id this build doesn't know.
    static func shortTitle(forTranscriptionEngineIdentifier identifier: String) -> String? {
        allCases.first { $0.transcriptionEngineIdentifier == identifier }?.shortTitle
            ?? legacyEngineShortTitles[identifier]
    }

    var transcriptionEngineIdentifier: String {
        switch self {
        case .parakeetTDTv3:
            return "parakeet_local"
        case .whisperLargeV3Turbo:
            return "whisper_large_v3_turbo_local"
        case .parakeetUltraExperimental:
            return "parakeet_ultra_local"
        }
    }

    var transcriptionEngineDisplayName: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .parakeetUltraExperimental:
            return "Parakeet Ultra"
        }
    }

    var whisperKitModelName: String? {
        switch self {
        case .parakeetTDTv3, .parakeetUltraExperimental:
            return nil
        case .whisperLargeV3Turbo:
            return "large-v3-v20240930_turbo_632MB"
        }
    }

    var approximateDownloadSize: String {
        switch self {
        case .parakeetTDTv3:
            return "~600 MB"
        case .whisperLargeV3Turbo:
            return "~632 MB"
        case .parakeetUltraExperimental:
            // Installed locally by the conversion script, never downloaded.
            return "~600 MB"
        }
    }

    var parakeetVariant: ParakeetModelVariant? {
        switch self {
        case .parakeetTDTv3: return .v3
        case .parakeetUltraExperimental: return .ultra
        case .whisperLargeV3Turbo: return nil
        }
    }
}

/// Experimental script-installed models stay out of the picker until they are
/// installed, so nobody can pick a model that cannot load. The current choice
/// always stays listed so the picker never shows a blank selection.
enum TranscriptionModelVisibilityPolicy {
    static func isVisible(
        _ model: TranscriptionModelChoice,
        selectedModel: TranscriptionModelChoice,
        isLocallyInstalled: (ParakeetModelVariant) -> Bool
    ) -> Bool {
        guard let variant = model.parakeetVariant, variant.isLocalInstallOnly else { return true }
        return model == selectedModel || isLocallyInstalled(variant)
    }
}

enum TranscriptionModelPreferences {
    static let defaultModel: TranscriptionModelChoice = .parakeetTDTv3

    private static let preferredModelKey = "transcription-model-preference"

    /// Resolves a stored preference rawValue to an active model choice,
    /// migrating retired choices to their closest supported successor
    /// (`whisper-large-v3` -> `.whisperLargeV3Turbo`, retired Parakeet V2 /
    /// Apple Speech / Nemotron / legacy aliases -> `.parakeetTDTv3`).
    static func migratedModel(forStoredRawValue rawValue: String) -> TranscriptionModelChoice? {
        if let model = TranscriptionModelChoice(rawValue: rawValue) {
            return model
        }
        switch rawValue {
        case "whisper-large-v3":
            return .whisperLargeV3Turbo
        case "parakeet-tdt-v2", "apple-speech", "parakeet-ultra", "nemotron-streaming-0.6b":
            return .parakeetTDTv3
        default:
            return nil
        }
    }

    /// Retired stored raw values migrate to their closest supported model;
    /// unknown raw values fall back to the default model.
    static func preferredModel(userDefaults: UserDefaults = .standard) -> TranscriptionModelChoice {
        guard let rawValue = userDefaults.string(forKey: preferredModelKey) else {
            return defaultModel
        }

        return migratedModel(forStoredRawValue: rawValue) ?? defaultModel
    }

    static func setPreferredModel(_ model: TranscriptionModelChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(model.rawValue, forKey: preferredModelKey)
        NotificationCenter.default.post(name: .transcriptionModelPreferenceDidChange, object: nil)
    }
}

extension Notification.Name {
    static let transcriptionModelPreferenceDidChange = Notification.Name("transcriptionModelPreferenceDidChange")
}
