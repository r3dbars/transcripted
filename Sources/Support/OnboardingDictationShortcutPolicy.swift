import Foundation

enum OnboardingDictationShortcutPolicy {
    enum UseCase {
        case meetings
        case dictation
    }

    static func apply(
        useCase: UseCase,
        leaveDictationShortcutsOff: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        switch useCase {
        case .meetings:
            HotkeyPreferences.setDictationShortcutsEnabled(!leaveDictationShortcutsOff, userDefaults: userDefaults)
        case .dictation:
            HotkeyPreferences.setDictationShortcutsEnabled(true, userDefaults: userDefaults)
        }
    }
}
