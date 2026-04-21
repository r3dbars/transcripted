import Foundation

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetTDTv3 = "parakeet-tdt-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case whisperLargeV3 = "whisper-large-v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetTDTv3:
            return "Parakeet TDT V3"
        case .whisperLargeV3Turbo:
            return "Whisper Large V3 Turbo"
        case .whisperLargeV3:
            return "Whisper Large V3"
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
        }
    }

    var availabilityStatus: String {
        "Available"
    }

    var isRuntimeAvailable: Bool {
        true
    }

    var isWhisper: Bool {
        switch self {
        case .parakeetTDTv3:
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
        }
    }

    var whisperKitModelName: String? {
        switch self {
        case .parakeetTDTv3:
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
        return preferred.isRuntimeAvailable ? preferred : defaultModel
    }

    static func setPreferredModel(_ model: TranscriptionModelChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(model.rawValue, forKey: preferredModelKey)
        NotificationCenter.default.post(name: .transcriptionModelPreferenceDidChange, object: nil)
    }
}

extension Notification.Name {
    static let transcriptionModelPreferenceDidChange = Notification.Name("transcriptionModelPreferenceDidChange")
}
