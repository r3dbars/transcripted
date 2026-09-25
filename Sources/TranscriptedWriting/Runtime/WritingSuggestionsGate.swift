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
/// Phase 3's app scope ("All apps" / "Only apps I pick") extends `Inputs`
/// and `allows` here, and nowhere else.
enum WritingSuggestionsGate {
    struct Inputs: Equatable, Sendable {
        var suggestionsEnabled: Bool
        var pausedUntil: Date?
        var screenMemoryEnabled: Bool
        var screenRecordingGranted: Bool
        var now: Date
    }

    static func allows(_ inputs: Inputs) -> Bool {
        guard inputs.suggestionsEnabled else { return false }
        if let pausedUntil = inputs.pausedUntil, pausedUntil > inputs.now { return false }
        return ScreenMemoryStatus.evaluate(
            enabled: inputs.screenMemoryEnabled,
            permissionGranted: inputs.screenRecordingGranted
        ).allowsSuggestions
    }
}

extension WritingSuggestionsGate.Inputs {
    init(settings: TildeSettings, screenRecordingGranted: Bool, now: Date = Date()) {
        self.init(
            suggestionsEnabled: settings.suggestionsEnabled,
            pausedUntil: settings.pausedUntil,
            screenMemoryEnabled: settings.screenMemoryEnabled,
            screenRecordingGranted: screenRecordingGranted,
            now: now
        )
    }
}
