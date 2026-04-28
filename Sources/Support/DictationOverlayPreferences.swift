// Support/DictationOverlayPreferences.swift
// Opt-in presentation style for the live dictation overlay.

import Foundation

enum DictationOverlayPresentation: String, CaseIterable, Hashable, Identifiable {
    case nearText = "near-text"
    case dockShelf = "dock-shelf"

    var id: String { rawValue }
}

enum DictationOverlayPreferences {
    static let presentationKey = "dictation-overlay-presentation"
    static let defaultPresentation: DictationOverlayPresentation = .nearText

    static func presentation(
        userDefaults: UserDefaults = .standard
    ) -> DictationOverlayPresentation {
        guard let rawValue = userDefaults.string(forKey: presentationKey),
              let presentation = DictationOverlayPresentation(rawValue: rawValue) else {
            return defaultPresentation
        }
        return presentation
    }

    static func setPresentation(
        _ presentation: DictationOverlayPresentation,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(presentation.rawValue, forKey: presentationKey)
        NotificationCenter.default.post(name: .dictationOverlayPreferencesDidChange, object: nil)
    }

    static func isDockShelfEnabled(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        presentation(userDefaults: userDefaults) == .dockShelf
    }
}

extension Notification.Name {
    static let dictationOverlayPreferencesDidChange = Notification.Name("dictationOverlayPreferencesDidChange")
}
