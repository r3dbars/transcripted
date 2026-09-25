#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Writing's own preferences next to Tilde's `TildeSettings` (plan decisions
/// 3, 4 and 11). Each lives where its readers can see it:
///
/// - **Save my writing** is Tilde's Personal History switch, in the keyboard
///   suite, because the keyboard checks it before capturing. Change it
///   through `PersonalHistoryController.isEnabled` so consent rotates.
/// - **Personalized suggestions** is app-only, off by default. Only the app
///   serves personal suggestions.
/// - **App scope** is in the keyboard suite with a revision, because the
///   keyboard gates capture and suggestions on it.
struct WritingPreferences {
    enum AppKey: String {
        case personalizedSuggestions = "PersonalizedSuggestionsEnabled"
    }

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

    var personalizedSuggestionsEnabled: Bool {
        get { app.bool(forKey: AppKey.personalizedSuggestions.rawValue) }
        nonmutating set { app.set(newValue, forKey: AppKey.personalizedSuggestions.rawValue) }
    }

    /// `GhostBrainServerHost`'s `personalSuggestionsGate`. The predictor only
    /// learns while Save my writing is on, so both have to be on.
    var personalSuggestionsAllowed: Bool {
        saveMyWritingEnabled && personalizedSuggestionsEnabled
    }

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

    /// The one scope rule: capture, the day files, Screen Memory context and
    /// suggestions all ask this (the keyboard asks the same `WritingAppScope`).
    func allows(appBundleIdentifier: String?) -> Bool {
        appScope.allows(appBundleIdentifier, excludedApps: tildeSettings.personalHistoryExcludedApps)
    }
}
