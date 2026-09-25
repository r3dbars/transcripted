#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// The one app-side decision whether a completion request may be answered,
/// wired as `GhostBrainServerHost`'s `suggestionsGate` and read fresh on
/// every request. A `false` answers `.silence(reason: .suggestionsPaused)`.
///
/// Tilde's gate is the Screen Memory rule: Screen Memory on and Screen
/// Recording granted (`ScreenMemoryStatus.allowsSuggestions`). The on switch
/// and the pause are the keyboard's, which checks them on every key; they
/// are repeated here so the app never serves a suggestion the keyboard
/// wouldn't have asked for.
///
/// Phase 3 adds the app scope ("All apps" / "Only apps I pick") and the
/// exclusion list, checked against the request's app: the same rule capture
/// uses, and the keyboard checks it too. Tilde's exclusions never stopped the
/// ghost; setup promises "Autocomplete uses the same apps".
enum WritingSuggestionsGate {
    struct Inputs: Equatable, Sendable {
        var suggestionsEnabled: Bool
        var pausedUntil: Date?
        var screenMemoryEnabled: Bool
        var screenRecordingGranted: Bool
        var now: Date
        var appBundleIdentifier: String? = nil
        var appScope: WritingAppScope = .all
        var excludedApps: Set<String> = []
    }

    static func allows(_ inputs: Inputs) -> Bool {
        guard inputs.suggestionsEnabled else { return false }
        if let pausedUntil = inputs.pausedUntil, pausedUntil > inputs.now { return false }
        guard inputs.appScope.allows(inputs.appBundleIdentifier, excludedApps: inputs.excludedApps) else {
            return false
        }
        return ScreenMemoryStatus.evaluate(
            enabled: inputs.screenMemoryEnabled,
            permissionGranted: inputs.screenRecordingGranted
        ).allowsSuggestions
    }
}

extension WritingSuggestionsGate.Inputs {
    init(
        preferences: WritingPreferences,
        appBundleIdentifier: String?,
        screenRecordingGranted: Bool,
        now: Date = Date()
    ) {
        let settings = preferences.tildeSettings
        self.init(
            suggestionsEnabled: settings.suggestionsEnabled,
            pausedUntil: settings.pausedUntil,
            screenMemoryEnabled: settings.screenMemoryEnabled,
            screenRecordingGranted: screenRecordingGranted,
            now: now,
            appBundleIdentifier: appBundleIdentifier,
            appScope: preferences.appScope,
            excludedApps: settings.personalHistoryExcludedApps
        )
    }
}
