import AppKit

enum UISoundPreferences {
    private static let enabledKey = "enableUISounds"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

enum DictationSounds {
    enum Cue {
        case start
        case stop
        case pasted
        case cancel
        case noSpeech
        case error
    }

    static func play(_ cue: Cue, userDefaults: UserDefaults = .standard) {
        guard UISoundPreferences.isEnabled(userDefaults: userDefaults) else { return }
        guard let sound = NSSound(named: NSSound.Name(systemSoundName(for: cue))) else { return }
        sound.volume = 0.3
        sound.play()
    }

    static func systemSoundName(for cue: Cue) -> String {
        switch cue {
        case .start:
            return "Pop"
        case .stop:
            return "Tink"
        case .pasted:
            return "Glass"
        case .cancel, .noSpeech, .error:
            return "Basso"
        }
    }
}
