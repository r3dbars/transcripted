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

    /// The local EmbeddingGemma server (llama.cpp `llama-server --embedding`) that finds context by
    /// meaning. Everything it sees stays on this Mac. If it isn't running and the server and model
    /// paths are set, Next Sentence starts it.
    static let embeddingURLKey = "NextSentenceEmbeddingURL"
    static let embeddingServerKey = "NextSentenceEmbeddingServer"
    static let embeddingModelKey = "NextSentenceEmbeddingModel"
    static let defaultEmbeddingURL = "http://127.0.0.1:8811"

    static func embeddingURL(userDefaults: UserDefaults = .standard) -> URL? {
        URL(string: userDefaults.string(forKey: embeddingURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultEmbeddingURL)
    }

    /// The server binary and model, when both are set.
    static func embeddingLaunch(userDefaults: UserDefaults = .standard) -> (server: String, model: String)? {
        guard let server = userDefaults.string(forKey: embeddingServerKey), !server.isEmpty,
              let model = userDefaults.string(forKey: embeddingModelKey), !model.isEmpty else { return nil }
        return (server, model)
    }

    /// Which Claude model writes. The reply you read first uses `replyModelKey` (Opus by default);
    /// the background work (every tone and length, word swaps, rephrasings) uses `backgroundModelKey`
    /// (Sonnet by default, about half the usage). Any `claude --model` name works: opus, sonnet, haiku.
    static let replyModelKey = "NextSentenceReplyModel"
    static let backgroundModelKey = "NextSentenceBackgroundModel"

    static func replyModel(userDefaults: UserDefaults = .standard) -> String {
        userDefaults.string(forKey: replyModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? "opus"
    }

    static func backgroundModel(userDefaults: UserDefaults = .standard) -> String {
        userDefaults.string(forKey: backgroundModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? "sonnet"
    }

    /// The card's sounds. On unless set to NO.
    static let soundsKey = "NextSentenceSounds"

    static func soundsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: soundsKey) == nil || userDefaults.bool(forKey: soundsKey)
    }

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func claudePathOverride(userDefaults: UserDefaults = .standard) -> String? {
        guard let path = userDefaults.string(forKey: claudePathKey), !path.isEmpty else { return nil }
        return path
    }
}
