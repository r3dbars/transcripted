import Foundation

/// Next Sentence: a hotkey that writes the next sentence you'd type, from what's on screen and
/// your saved meetings, dictations and writing, and pastes the one you pick.
///
/// Owner-only lab feature. It's off unless the hidden default is set, has no Settings UI, and
/// sends the focused window's screenshot, its text and matching snippets to Claude through the
/// `claude` CLI the user is signed into. That breaks Writing's "never leaves your Mac" promise,
/// so it must not reach other users until it has its own opt-in, copy and AGENTS.md rule update.
///
/// Turn it on: `defaults write com.justinbetker.draft NextSentenceEnabled -bool YES`, then relaunch.
enum NextSentencePreferences {
    static let enabledKey = "NextSentenceEnabled"
    /// Full path to the `claude` CLI when it isn't in one of the usual places.
    static let claudePathKey = "NextSentenceClaudePath"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func claudePathOverride(userDefaults: UserDefaults = .standard) -> String? {
        guard let path = userDefaults.string(forKey: claudePathKey), !path.isEmpty else { return nil }
        return path
    }
}
