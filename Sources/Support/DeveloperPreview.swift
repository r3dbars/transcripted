import Foundation

/// One Developer Preview feature: something that works but isn't finished, which people turn on
/// themselves in Settings › Developer Preview. It says plainly what it does and what leaves the Mac.
struct DeveloperPreviewFeature: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The ⓘ popover: what it does, and what it sends anywhere.
    let details: String
    /// Asked each time it's turned on.
    let consentTitle: String
    let consent: String
    let defaultsKey: String
}

/// Developer Preview: every feature is off until the person turns it on, and turning one on asks
/// first. Changing one posts `didChange` (its id as the object) so the app starts or stops it at once.
enum DeveloperPreview {
    static let didChange = Notification.Name("DeveloperPreviewDidChange")

    /// Write for Me: what people see for Next Sentence (`Sources/Writing/NextSentence/`).
    static let nextSentence = DeveloperPreviewFeature(
        id: "next-sentence",
        title: "Write for Me",
        details: "Press fn in any text box and Claude writes your next message, from the window you're in and your meetings, "
            + "dictations and writing. Hold fn to say what it should say. It sends that window's screenshot and text, and "
            + "matching passages from your captures, to Claude through Claude Code signed in on this Mac. Needs Claude Code.",
        consentTitle: "Turn on Write for Me?",
        consent: "When you press fn, Write for Me sends the window you're typing in (a screenshot and its text) and matching "
            + "passages from your meetings, dictations and writing to Claude, using your own Claude Code sign-in. "
            + "Nothing is sent until you press fn.",
        defaultsKey: NextSentencePreferences.enabledKey
    )

    static let all = [nextSentence]

    static func isOn(_ feature: DeveloperPreviewFeature, userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: feature.defaultsKey)
    }

    static func set(_ feature: DeveloperPreviewFeature, on: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(on, forKey: feature.defaultsKey)
        NotificationCenter.default.post(name: didChange, object: feature.id)
    }
}
