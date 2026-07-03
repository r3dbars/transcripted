import Foundation

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetTDTv3 = "parakeet-tdt-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case whisperLargeV3 = "whisper-large-v3"
    case nemotronStreaming = "nemotron-streaming-0.6b"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet TDT V3"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .whisperLargeV3:
            return "Whisper Large V3"
        case .nemotronStreaming:
            return "Nemotron Streaming (Beta)"
        }
    }

    var shortTitle: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet"
        case .whisperLargeV3Turbo:
            return "Whisper Turbo"
        case .whisperLargeV3:
            return "Whisper"
        case .nemotronStreaming:
            return "Nemotron"
        }
    }

    var summary: String {
        switch self {
        case .parakeetTDTv3:
            return "Default local model for dictation and meetings."
        case .whisperLargeV3Turbo:
            return "Local Whisper with broad language coverage."
        case .whisperLargeV3:
            return "Local Whisper for maximum multilingual accuracy."
        case .nemotronStreaming:
            return "Local streaming model covering 40 languages, including CJK and Arabic."
        }
    }

    var availabilityStatus: String {
        "Available"
    }

    /// Whether this model may be used as the effective runtime right now.
    /// Nemotron is beta-gated: when the opt-in flag is off,
    /// `TranscriptionModelPreferences.effectiveModel()` self-heals back to the
    /// Parakeet default even if the saved preference still names Nemotron.
    var isRuntimeAvailable: Bool {
        isRuntimeAvailable()
    }

    func isRuntimeAvailable(userDefaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .parakeetTDTv3, .whisperLargeV3Turbo, .whisperLargeV3:
            return true
        case .nemotronStreaming:
            return SpeechModelBetaPreferences.nemotronBetaEnabled(userDefaults: userDefaults)
        }
    }

    var isWhisper: Bool {
        switch self {
        case .parakeetTDTv3, .nemotronStreaming:
            return false
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return true
        }
    }

    var engineName: String {
        switch self {
        case .parakeetTDTv3:
            return "parakeet"
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return "whisper"
        case .nemotronStreaming:
            return "nemotron"
        }
    }

    var transcriptionEngineIdentifier: String {
        switch self {
        case .parakeetTDTv3:
            return "parakeet_local"
        case .whisperLargeV3Turbo:
            return "whisper_large_v3_turbo_local"
        case .whisperLargeV3:
            return "whisper_large_v3_local"
        case .nemotronStreaming:
            return "nemotron_streaming_local"
        }
    }

    var transcriptionEngineDisplayName: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .whisperLargeV3:
            return "Whisper Large V3"
        case .nemotronStreaming:
            return "Nemotron Streaming"
        }
    }

    var whisperKitModelName: String? {
        switch self {
        case .parakeetTDTv3, .nemotronStreaming:
            return nil
        case .whisperLargeV3Turbo:
            return "large-v3-v20240930_turbo_632MB"
        case .whisperLargeV3:
            return "large-v3-v20240930_626MB"
        }
    }

    var approximateDownloadSize: String {
        switch self {
        case .parakeetTDTv3:
            return "~600 MB"
        case .whisperLargeV3Turbo:
            return "~632 MB"
        case .whisperLargeV3:
            return "~626 MB"
        case .nemotronStreaming:
            return "~600 MB"
        }
    }
}

enum TranscriptionModelPreferences {
    static let defaultModel: TranscriptionModelChoice = .parakeetTDTv3

    private static let preferredModelKey = "transcription-model-preference"

    static func preferredModel(userDefaults: UserDefaults = .standard) -> TranscriptionModelChoice {
        guard
            let rawValue = userDefaults.string(forKey: preferredModelKey),
            let model = TranscriptionModelChoice(rawValue: rawValue)
        else {
            return defaultModel
        }

        return model
    }

    static func effectiveModel(userDefaults: UserDefaults = .standard) -> TranscriptionModelChoice {
        let preferred = preferredModel(userDefaults: userDefaults)
        return preferred.isRuntimeAvailable(userDefaults: userDefaults) ? preferred : defaultModel
    }

    static func setPreferredModel(_ model: TranscriptionModelChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(model.rawValue, forKey: preferredModelKey)
        NotificationCenter.default.post(name: .transcriptionModelPreferenceDidChange, object: nil)
    }
}

extension Notification.Name {
    static let transcriptionModelPreferenceDidChange = Notification.Name("transcriptionModelPreferenceDidChange")
}
