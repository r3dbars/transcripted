#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Opt-in writing capture preferences shared with the keyboard process:
/// - **Save my writing** (`personalHistoryEnabled`), off by default.
/// - **App scope** (`WritingAppScope`), stored with a revision so the keyboard
///   re-reads it only when it changes.
struct WritingPreferences {
    private let keyboard: UserDefaults
    private let app: UserDefaults

    init(
        keyboard: UserDefaults? = UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
        app: UserDefaults = .standard
    ) {
        self.keyboard = keyboard ?? .standard
        self.app = app
    }

    var tildeSettings: TildeSettings {
        TildeSettings(keyboard: keyboard, app: app)
    }

    var saveMyWritingEnabled: Bool { tildeSettings.personalHistoryEnabled }

    var appScope: WritingAppScope {
        get {
            WritingAppScope(
                storedMode: keyboard.string(forKey: WritingAppScope.modeKey),
                storedBundleIdentifiers: keyboard.stringArray(forKey: WritingAppScope.bundleIdentifiersKey)
            )
        }
        nonmutating set {
            keyboard.set(newValue.bundleIdentifiers, forKey: WritingAppScope.bundleIdentifiersKey)
            keyboard.set(newValue.mode.rawValue, forKey: WritingAppScope.modeKey)
            // Last, so the keyboard re-reads only once both values are in.
            keyboard.set(
                keyboard.integer(forKey: WritingAppScope.revisionKey) &+ 1,
                forKey: WritingAppScope.revisionKey
            )
        }
    }

    /// The one scope rule for both the keyboard and the day-file recorder.
    func allows(appBundleIdentifier: String?) -> Bool {
        appScope.allows(appBundleIdentifier, excludedApps: tildeSettings.personalHistoryExcludedApps)
    }
}
