import AppKit

/// Next Sentence's card window. By default it never takes focus: the app being typed in stays key,
/// and keys reach the card through `NextSentenceKeyTap`. While the user edits the card's text it
/// may take the keyboard, without activating Transcripted (it's a non-activating panel), and gives
/// it back on Insert or Esc. It shows text written from the user's screen and saved context, so it
/// stays out of screen sharing unless the island is allowed in it too.
final class NextSentencePanel: NSPanel {
    /// True only while the user is editing the card's text.
    var allowsKeyboard = false

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        sharingType = .none
    }

    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Follows the island's "Show in screen sharing" choice; hidden by default.
    func applyScreenSharingPreference(userDefaults: UserDefaults = .standard) {
        sharingType = NotchIslandPreferences.visibleInScreenSharing(userDefaults: userDefaults) ? .readOnly : .none
    }
}
