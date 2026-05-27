import Foundation

enum DictationOverlayPresentationMode: String, CaseIterable, Identifiable, Hashable {
    case nearText
    case cursorMini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearText:
            return "Near text box"
        case .cursorMini:
            return "Mini cursor"
        }
    }

    var detail: String {
        switch self {
        case .nearText:
            return "Full dictation window appears near the active text box."
        case .cursorMini:
            return "Tiny waveform follows the cursor. Stop with your dictation shortcut or Escape."
        }
    }
}

enum DictationOverlayPresentationPreferences {
    static let modeKey = "dictationOverlayPresentationMode"
    static let defaultMode: DictationOverlayPresentationMode = .nearText

    static func mode(userDefaults: UserDefaults = .standard) -> DictationOverlayPresentationMode {
        guard
            let rawValue = userDefaults.string(forKey: modeKey),
            let mode = DictationOverlayPresentationMode(rawValue: rawValue)
        else {
            return defaultMode
        }
        return mode
    }

    static func setMode(_ mode: DictationOverlayPresentationMode, userDefaults: UserDefaults = .standard) {
        userDefaults.set(mode.rawValue, forKey: modeKey)
    }
}
