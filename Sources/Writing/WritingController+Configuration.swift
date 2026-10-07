#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import CoreGraphics
import Foundation

// Static keys, the defaults suites, and the settings readers, split out of
// `WritingController.swift` to keep it under the file-size cap.

extension WritingController {
    /// Tilde's app-owned keys (`TildeSettings.AppKey`, the model choice) live
    /// in this suite, apart from Transcripted's `.standard`. The keyboard's
    /// keys stay in the keyboard's own domain, shared with its process.
    nonisolated static let appSuiteName = "com.justinbetker.draft.writing"
    /// Phase 2's switch in Transcripted's `.standard` defaults, kept for
    /// development: it starts Writing even before setup finishes.
    nonisolated static let debugEnabledKey = "WritingDebugEnabled"
    /// Keyboard-suite flag: when set, the keyboard stops opening the app
    /// after a failed request. Tilde's name, which the keyboard reads.
    nonisolated static let quietQuitKey = "GhostBrainQuietQuit"

    /// Set by `noteTerminationRequest()` when macOS itself is quitting the
    /// app (logout, restart, shutdown). Only a quit the user chose sets the
    /// keyboard's quiet-quit flag.
    private(set) static var terminationIsSystemInitiated = false

    /// Call first thing in `applicationShouldTerminate`. The system attaches
    /// a quit reason to the quit Apple event it sends at logout, restart and
    /// shutdown; ⌘Q, the menu Quit items and Sparkle's relaunch don't.
    static func noteTerminationRequest() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let hasSystemQuitReason = event?.eventID == AEEventID(kAEQuitApplication)
            && event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        terminationIsSystemInitiated = hasSystemQuitReason
    }
    /// App-suite flag: the keyboard was enabled and selected once. Later
    /// starts leave Input Sources to the user.
    nonisolated static let keyboardFirstSetupKey = "KeyboardEnabledAndSelectedOnce"

    nonisolated static var defaultModelRoot: URL {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("writing", isDirectory: true)
    }

    nonisolated static func appDefaults() -> UserDefaults {
        UserDefaults(suiteName: appSuiteName) ?? .standard
    }

    /// A fresh view of every Writing setting, read on each use like Tilde's
    /// `TildeSettings()`, so a change from either process applies at once.
    nonisolated static func settings() -> TildeSettings {
        TildeSettings(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }

    /// Writing's own preferences (Save my writing, personalized suggestions,
    /// the app scope), read fresh on each use like `settings()`.
    nonisolated static func preferences() -> WritingPreferences {
        WritingPreferences(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }
}
