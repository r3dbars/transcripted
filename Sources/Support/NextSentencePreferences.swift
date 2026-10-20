import Foundation

/// Next Sentence: a hotkey that writes the next sentence you'd type, from what's on screen and
/// your saved meetings, dictations and writing, and pastes the one you pick.
///
/// A Developer Preview feature (`DeveloperPreview.nextSentence`): off until the person turns it on in
/// Settings › Developer Preview, which says what it sends and asks first. When used it sends the focused
/// window's screenshot, its text and matching snippets to Claude through the `claude` CLI they're
/// signed into, the one exception to "Local-first and private" in AGENTS.md.
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

    /// How hard Claude thinks before writing: low (default, fastest), medium or high.
    static let effortKey = "NextSentenceEffort"

    static func effort(userDefaults: UserDefaults = .standard) -> String {
        userDefaults.string(forKey: effortKey).flatMap { $0.isEmpty ? nil : $0 } ?? "low"
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

/// The key that opens Write for Me: one key on its own, tapped to open the card and held to speak.
/// Any modifier key (either side) or a function key, F1 to F20.
struct NextSentenceHotkey: Hashable, Sendable {
    let keyCode: Int64

    static let fn = NextSentenceHotkey(keyCode: 63)
    /// The quick choices in Settings; "Record…" takes any other allowed key.
    static let presets = [fn, NextSentenceHotkey(keyCode: 54), NextSentenceHotkey(keyCode: 62),
                          NextSentenceHotkey(keyCode: 60), NextSentenceHotkey(keyCode: 61)]

    /// Modifier keys: the bit a flags-changed event carries while each is down. fn has its own flag; the
    /// others have per-side device bits (IOLLEvent.h), so left and right are different keys.
    private static let modifiers: [Int64: (mask: UInt64, title: String, short: String)] = [
        63: (0x80_0000, "fn (Globe)", "fn"),
        55: (0x08, "Left Command ⌘", "left ⌘"), 54: (0x10, "Right Command ⌘", "right ⌘"),
        58: (0x20, "Left Option ⌥", "left ⌥"), 61: (0x40, "Right Option ⌥", "right ⌥"),
        59: (0x01, "Left Control ⌃", "left ⌃"), 62: (0x2000, "Right Control ⌃", "right ⌃"),
        56: (0x02, "Left Shift ⇧", "left ⇧"), 60: (0x04, "Right Shift ⇧", "right ⇧"),
    ]
    private static let functionKeys: [Int64: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// Nil for a key that can't be Write for Me's key (letters, numbers, Space, Return...).
    init?(recorded keyCode: Int64) {
        guard Self.modifiers[keyCode] != nil || Self.functionKeys[keyCode] != nil else { return nil }
        self.keyCode = keyCode
    }

    private init(keyCode: Int64) { self.keyCode = keyCode }

    var isModifier: Bool { Self.modifiers[keyCode] != nil }
    /// For a modifier key, the flag bit that's set while it's down.
    var downMask: UInt64? { Self.modifiers[keyCode]?.mask }

    var title: String { Self.modifiers[keyCode]?.title ?? "F\(Self.functionKeys[keyCode] ?? 0)" }
    /// For hints on the card: "tap fn", "let go of right ⌘", "tap F5".
    var shortName: String { Self.modifiers[keyCode]?.short ?? title }
}

extension NextSentencePreferences {
    static let hotkeyKey = "NextSentenceHotkeyCode"

    static func hotkey(userDefaults: UserDefaults = .standard) -> NextSentenceHotkey {
        guard userDefaults.object(forKey: hotkeyKey) != nil else { return .fn }
        return NextSentenceHotkey(recorded: Int64(userDefaults.integer(forKey: hotkeyKey))) ?? .fn
    }

    static func setHotkey(_ key: NextSentenceHotkey, userDefaults: UserDefaults = .standard) {
        userDefaults.set(Int(key.keyCode), forKey: hotkeyKey)
    }

    /// Transcripted's dictation key is this same key on its own, so one press would do both.
    static func hotkeyClashesWithDictation(_ key: NextSentenceHotkey, userDefaults: UserDefaults = .standard) -> Bool {
        let dictation = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: userDefaults)
        return dictation.modifiers == 0 && Int64(dictation.keyCode) == key.keyCode
    }
}
