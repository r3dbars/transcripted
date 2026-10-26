#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Where Write for Me won't read the screen, and what it takes out of what it reads before any of it
/// goes to Claude. Pure, so tests pin it; `NextSentenceContext` supplies the real app and settings.
enum NextSentencePrivacy {
    enum Block: Equatable {
        case noFrontmostApp
        /// Transcripted itself.
        case ownApp
        /// A password manager, or an app on their Screen Memory exclusion list.
        case excludedApp
        /// A password field (or anything else that turned on secure input) has the keyboard.
        case secureInput
    }

    /// The same refusals as Screen Memory: never Transcripted itself, never secure input, never a password
    /// manager or an app the person excluded (`excludedApps`, Screen Memory's list).
    static func blockReason(processIdentifier: pid_t?, bundleIdentifier: String?, ownProcessIdentifier: pid_t,
                            secureInput: Bool, excludedApps: Set<String>) -> Block? {
        guard let processIdentifier else { return .noFrontmostApp }
        if processIdentifier == ownProcessIdentifier { return .ownApp }
        if let bundleIdentifier, DefaultExcludedApps.isExcluded(bundleIdentifier, configuredExcludedApps: excludedApps) {
            return .excludedApp
        }
        if secureInput { return .secureInput }
        return nil
    }

    /// The card's note when it won't open.
    static func message(for block: Block) -> String {
        switch block {
        case .excludedApp: return "Write for Me doesn't run in this app."
        case .secureInput: return "Write for Me doesn't run in password fields."
        case .noFrontmostApp, .ownApp: return "Click into a text box first."
        }
    }

    /// Text from the screen with passwords, codes, card numbers and keys taken out, the same way Save my
    /// writing scrubs a day file. Run over everything read from the window before it's used or sent.
    static func scrub(_ text: String, appBundleIdentifier: String?) -> String {
        guard !text.isEmpty else { return text }
        return WritingSecretScrubber.scrub(text, appBundleIdentifier: appBundleIdentifier ?? "").clean
    }
}
