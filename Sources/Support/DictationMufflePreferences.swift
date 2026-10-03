import Foundation

/// "Muffle other audio while dictating": while the mic is open for dictation,
/// music and video from other apps keep playing but sound low-passed, like
/// stepping outside the club. Off until the user turns it on, because it
/// needs System Audio Recording access and changes what other apps sound like.
enum DictationMufflePreferences {
    static let enabledKey = "dictationMuffleOtherAudioEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
