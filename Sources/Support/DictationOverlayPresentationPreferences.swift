import Foundation

enum DictationOverlayPresentationMode: String, CaseIterable, Identifiable, Hashable {
    case nearText
    case cursorMini
    /// One black island at the top of the screen, grown out of the MacBook
    /// notch (or hanging from the top edge of a display without one). It also
    /// carries meetings and the call-detected prompt, see NotchIslandController.
    case notchIsland

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearText:
            return "Near text box"
        case .cursorMini:
            return "Mini cursor"
        case .notchIsland:
            return "Notch island"
        }
    }

    var detail: String {
        switch self {
        case .nearText:
            return "Full dictation window appears near the active text box."
        case .cursorMini:
            return "Tiny waveform follows the cursor. Stop with your dictation shortcut. Esc cancels."
        case .notchIsland:
            return "Grows out of the notch, or the top of other displays. Meetings use it too."
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

/// Whether the notch island shows up in screen sharing, screen recordings
/// and screenshots. Off by default, like every other overlay, so a shared
/// screen never shows live dictation; people who want to demo or capture it
/// turn it on.
enum NotchIslandPreferences {
    static let visibleInScreenSharingKey = "notchIslandVisibleInScreenSharing"

    static func visibleInScreenSharing(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: visibleInScreenSharingKey)
    }

    static func setVisibleInScreenSharing(_ visible: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(visible, forKey: visibleInScreenSharingKey)
    }
}
