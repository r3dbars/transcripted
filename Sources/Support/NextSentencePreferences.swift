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

/// What opens Write for Me: tapped to open the card, held to speak. Either one key on its own (any
/// modifier key, either side, or F1 to F20) or a combination of modifiers and a key, like ⌥D.
struct NextSentenceHotkey: Hashable, Sendable {
    let keyCode: Int64
    /// For a combination: the modifiers held with the key, as CGEventFlags bits (⌘ ⌥ ⌃ ⇧). 0 for one key.
    let modifiers: UInt64
    /// For a combination: the key's own label, as typed when it was recorded ("D").
    let label: String

    static let command: UInt64 = 0x10_0000
    static let option: UInt64 = 0x08_0000
    static let control: UInt64 = 0x04_0000
    static let shift: UInt64 = 0x02_0000
    static let chordMask = command | option | control | shift

    static let fn = NextSentenceHotkey(keyCode: 63, modifiers: 0, label: "")
    /// The quick choices in Settings (keys every Mac keyboard has); "Record…" takes anything else.
    static let presets = [fn, NextSentenceHotkey(keyCode: 54, modifiers: 0, label: ""),
                          NextSentenceHotkey(keyCode: 60, modifiers: 0, label: ""), NextSentenceHotkey(keyCode: 61, modifiers: 0, label: "")]

    /// Modifier keys: the bit a flags-changed event carries while each is down. fn has its own flag; the
    /// others have per-side device bits (IOLLEvent.h), so left and right are different keys.
    private static let modifierKeys: [Int64: (mask: UInt64, title: String, short: String)] = [
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
    private static let namedKeys: [Int64: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
                                                     123: "←", 124: "→", 125: "↓", 126: "↑"]

    /// One key on its own: nil unless it's a modifier key or a function key (a letter would stop typing).
    init?(recorded keyCode: Int64) {
        guard Self.modifierKeys[keyCode] != nil || Self.functionKeys[keyCode] != nil else { return nil }
        self.init(keyCode: keyCode, modifiers: 0, label: "")
    }

    /// A combination: nil without ⌘, ⌥ or ⌃ (⇧ alone would just type a capital), or if the key is itself a modifier.
    init?(recorded keyCode: Int64, modifiers: UInt64, label: String) {
        let chord = modifiers & Self.chordMask
        guard chord & (Self.command | Self.option | Self.control) != 0, Self.modifierKeys[keyCode] == nil else { return nil }
        self.init(keyCode: keyCode, modifiers: chord, label: label)
    }

    private init(keyCode: Int64, modifiers: UInt64, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    var isCombination: Bool { modifiers != 0 }
    var isModifier: Bool { !isCombination && Self.modifierKeys[keyCode] != nil }
    /// For a modifier key on its own, the flag bit that's set while it's down.
    var downMask: UInt64? { isCombination ? nil : Self.modifierKeys[keyCode]?.mask }

    var title: String {
        if isCombination {
            let symbols = [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
                .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            let key = Self.namedKeys[keyCode] ?? Self.functionKeys[keyCode].map { "F\($0)" } ?? label.uppercased()
            return symbols + (key.isEmpty ? "?" : key)
        }
        return Self.modifierKeys[keyCode]?.title ?? "F\(Self.functionKeys[keyCode] ?? 0)"
    }

    /// For hints on the card: "tap fn", "let go of right ⌘", "tap ⌥D".
    var shortName: String { isCombination ? title : Self.modifierKeys[keyCode]?.short ?? title }
}

extension NextSentencePreferences {
    static let hotkeyKey = "NextSentenceHotkeyCode"
    static let hotkeyModifiersKey = "NextSentenceHotkeyModifiers"
    static let hotkeyLabelKey = "NextSentenceHotkeyLabel"

    static func hotkey(userDefaults: UserDefaults = .standard) -> NextSentenceHotkey {
        guard userDefaults.object(forKey: hotkeyKey) != nil else { return .fn }
        let code = Int64(userDefaults.integer(forKey: hotkeyKey))
        let modifiers = UInt64(max(0, userDefaults.integer(forKey: hotkeyModifiersKey)))
        if modifiers != 0 {
            return NextSentenceHotkey(recorded: code, modifiers: modifiers, label: userDefaults.string(forKey: hotkeyLabelKey) ?? "") ?? .fn
        }
        return NextSentenceHotkey(recorded: code) ?? .fn
    }

    static func setHotkey(_ key: NextSentenceHotkey, userDefaults: UserDefaults = .standard) {
        userDefaults.set(Int(key.keyCode), forKey: hotkeyKey)
        userDefaults.set(Int(key.modifiers), forKey: hotkeyModifiersKey)
        userDefaults.set(key.label, forKey: hotkeyLabelKey)
    }

    /// What else in Transcripted already uses this key ("Dictation", "Meetings"), or nil if nothing does.
    static func hotkeyClash(_ key: NextSentenceHotkey, userDefaults: UserDefaults = .standard) -> String? {
        let uses = [("Dictation", PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: userDefaults)),
                    ("Meetings", PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: userDefaults))]
        return uses.first { Int64($0.1.keyCode) == key.keyCode && carbonModifiers(key.modifiers) == $0.1.modifiers & ~PhysicalDictationTriggerModifiers.function }?.0
    }

    /// The same modifiers in the bits the dictation and meeting keys are stored with.
    private static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        var result: UInt32 = 0
        if flags & NextSentenceHotkey.command != 0 { result |= PhysicalDictationTriggerModifiers.command }
        if flags & NextSentenceHotkey.shift != 0 { result |= PhysicalDictationTriggerModifiers.shift }
        if flags & NextSentenceHotkey.option != 0 { result |= PhysicalDictationTriggerModifiers.option }
        if flags & NextSentenceHotkey.control != 0 { result |= PhysicalDictationTriggerModifiers.control }
        return result
    }
}
