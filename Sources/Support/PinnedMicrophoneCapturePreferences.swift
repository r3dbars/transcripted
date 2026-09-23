import Foundation

/// Rollout switch for recording the chosen microphone through a Core Audio
/// IOProc on its device ID (`PinnedMicrophoneCapture`) instead of an
/// `AVAudioEngine` input node. A fresh input node opens the macOS default
/// input before it can be moved, which flips AirPods into call mode; the
/// pinned path never opens anything but the chosen mic.
///
/// Off by default until it passes hardware testing. Turn it on for a test
/// build with `defaults write com.justinbetker.draft pinned-microphone-capture -bool true`
/// or `TRANSCRIPTED_PINNED_MIC_CAPTURE=1`. Read at each meeting or dictation
/// start; Apple voice processing still uses `AVAudioEngine`.
enum PinnedMicrophoneCapturePreferences {
    static let userDefaultsKey = "pinned-microphone-capture"
    static let environmentKey = "TRANSCRIPTED_PINNED_MIC_CAPTURE"

    static func isEnabled(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let override = environment[environmentKey] {
            return ["1", "true", "yes"].contains(override.lowercased())
        }
        return userDefaults.bool(forKey: userDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: userDefaultsKey)
    }
}
