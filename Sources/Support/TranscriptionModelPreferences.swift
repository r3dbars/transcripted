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
            return "Default local model. Fast, bundled, and tuned for Transcripted's current dictation and meeting pipeline."
        case .whisperLargeV3Turbo:
            return "Advanced local option for broader language coverage once the Whisper runtime is bundled."
        case .whisperLargeV3:
            return "Advanced local option for maximum Whisper accuracy once the Whisper runtime is bundled."
        }
    }

    var availabilityStatus: String {
        isRuntimeAvailable ? "Available" : "Runtime needed"
    }

    var isRuntimeAvailable: Bool {
        switch self {
        case .parakeetTDTv3:
            return true
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return false
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
