import Foundation

/// App-owned model identity; conversion to FluidAudio stays at the Speech boundary.
enum ParakeetModelVariant: String, CaseIterable, Sendable {
    case v2
    case v3

    var directoryName: String { "parakeet-tdt-0.6b-\(rawValue)" }
    var jointModelName: String { self == .v2 ? "JointDecision.mlmodelc" : "JointDecisionv3.mlmodelc" }
    var requiredModelDirectoryNames: [String] {
        ["Encoder.mlmodelc", jointModelName, "Decoder.mlmodelc", "Preprocessor.mlmodelc"]
    }
    var requiredFileNames: [String] {
        // FluidAudio v0.15.4: ModelNames.swift and AsrModels.getRequiredModels
        // define the compiled model set; AsrModels loads the shared vocabulary
        // for v2. Recheck this contract when changing the dependency version.
        self == .v2 ? ["parakeet_vocab.json"] : ["config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"]
    }
}

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetTDTv3 = "parakeet-tdt-v3"
    case parakeetTDTv2 = "parakeet-tdt-v2"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case whisperLargeV3 = "whisper-large-v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet TDT V3"
        case .parakeetTDTv2:
            return "Parakeet TDT V2 (English only)"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .whisperLargeV3:
            return "Whisper Large V3"
        }
    }

    var shortTitle: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet V3"
        case .parakeetTDTv2:
            return "Parakeet V2"
        case .whisperLargeV3Turbo:
            return "Whisper Turbo"
        case .whisperLargeV3:
            return "Whisper"
        }
    }

    var summary: String {
        switch self {
        case .parakeetTDTv3:
            return "Default multilingual local model for dictation and meetings."
        case .parakeetTDTv2:
            return "English-only local model for dictation and meetings."
        case .whisperLargeV3Turbo:
            return "Local Whisper with broad language coverage."
        case .whisperLargeV3:
            return "Local Whisper for maximum multilingual accuracy."
        }
    }

    var availabilityStatus: String {
        "Available"
    }

    var isWhisper: Bool {
        switch self {
        case .parakeetTDTv2, .parakeetTDTv3:
            return false
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return true
        }
    }

    var engineName: String {
        switch self {
        case .parakeetTDTv2, .parakeetTDTv3:
            return "parakeet"
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return "whisper"
        }
    }

    var transcriptionEngineIdentifier: String {
        switch self {
        case .parakeetTDTv2:
            return "parakeet_v2_local"
        case .parakeetTDTv3:
            return "parakeet_local"
        case .whisperLargeV3Turbo:
            return "whisper_large_v3_turbo_local"
        case .whisperLargeV3:
            return "whisper_large_v3_local"
        }
    }

    var transcriptionEngineDisplayName: String {
        switch self {
        case .parakeetTDTv2:
            return "Parakeet V2"
        case .parakeetTDTv3:
            return "Parakeet"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .whisperLargeV3:
            return "Whisper Large V3"
        }
    }

    var whisperKitModelName: String? {
        switch self {
        case .parakeetTDTv2, .parakeetTDTv3:
            return nil
        case .whisperLargeV3Turbo:
            return "large-v3-v20240930_turbo_632MB"
        case .whisperLargeV3:
            return "large-v3-v20240930_626MB"
        }
    }

    var approximateDownloadSize: String {
        switch self {
        case .parakeetTDTv2:
            return "~460 MB"
        case .parakeetTDTv3:
            return "~600 MB"
        case .whisperLargeV3Turbo:
            return "~632 MB"
        case .whisperLargeV3:
            return "~626 MB"
        }
    }

    var parakeetVariant: ParakeetModelVariant? {
        switch self {
        case .parakeetTDTv2: return .v2
        case .parakeetTDTv3: return .v3
        case .whisperLargeV3Turbo, .whisperLargeV3: return nil
        }
    }
}

enum TranscriptionModelPreferences {
    static let defaultModel: TranscriptionModelChoice = .parakeetTDTv3

    private static let preferredModelKey = "transcription-model-preference"

    /// Unknown stored raw values (for example a model choice removed in a
    /// later release, like the retired Nemotron beta) fall back to the
    /// default model, so removals self-heal without a migration step.
    static func preferredModel(userDefaults: UserDefaults = .standard) -> TranscriptionModelChoice {
        guard
            let rawValue = userDefaults.string(forKey: preferredModelKey),
            let model = TranscriptionModelChoice(rawValue: rawValue)
        else {
            return defaultModel
        }

        return model
    }

    static func setPreferredModel(_ model: TranscriptionModelChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(model.rawValue, forKey: preferredModelKey)
        NotificationCenter.default.post(name: .transcriptionModelPreferenceDidChange, object: nil)
    }
}

extension Notification.Name {
    static let transcriptionModelPreferenceDidChange = Notification.Name("transcriptionModelPreferenceDidChange")
}
