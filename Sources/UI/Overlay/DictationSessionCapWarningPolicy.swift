import Foundation

/// The last-30-seconds warning before the 5-minute dictation cap.
///
/// It used to swap the listening pill for a "Long dictation" loading card that
/// told everyone to "release the key", even hands-free people with no key
/// held, and its "30 seconds left" never changed (the card's elapsed timer
/// tacked on "· 10s", "· 20s"). Now the pill keeps listening and its notice
/// counts down, worded for the shortcut that started the take.
enum DictationSessionCapWarningPolicy {
    /// The countdown shows once this many seconds are left.
    static let warningWindowSeconds: Double = 30

    static func shouldWarn(remainingSeconds: Double) -> Bool {
        remainingSeconds <= warningWindowSeconds
    }

    /// Whole seconds left, rounded up so the notice never reads "0s" while
    /// the take is still recording.
    static func displaySeconds(remainingSeconds: Double) -> Int {
        max(1, Int(remainingSeconds.rounded(.up)))
    }

    /// Short enough for the cursor mini pill, which shares this slot with
    /// "Press Esc again to discard".
    static func notice(remainingSeconds: Double, shortcutMode: DictationShortcutMode?) -> String {
        let countdown = "\(displaySeconds(remainingSeconds: remainingSeconds))s left"
        switch shortcutMode {
        case .pushToTalk:
            return "\(countdown) · let go to finish"
        case .handsFree:
            return "\(countdown) · press to finish"
        case nil:
            return countdown
        }
    }

    /// Spoken once when the countdown appears, for VoiceOver.
    static func announcement(shortcutMode: DictationShortcutMode?) -> String {
        let seconds = Int(warningWindowSeconds)
        switch shortcutMode {
        case .pushToTalk:
            return "Dictation stops in \(seconds) seconds. Let go of the key to finish now."
        case .handsFree:
            return "Dictation stops in \(seconds) seconds. Press your dictation shortcut to finish now."
        case nil:
            return "Dictation stops in \(seconds) seconds."
        }
    }

    /// True for any notice this policy wrote, so clearing it never wipes the
    /// Esc confirm prompt.
    static func isCapNotice(_ notice: String) -> Bool {
        notice.range(of: #"^\d+s left"#, options: .regularExpression) != nil
    }
}
