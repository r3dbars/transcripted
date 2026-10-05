// AppLaunchSteps.swift
// Launch work the app delegate runs once its controllers are wired. Kept as a
// list so tests can check each step is still there and still runs.

/// The dictation side of launch. `DictationSessionController` conforms.
@MainActor
protocol AppLaunchDictationHost: AnyObject {
    /// Deletes short (under 30 s) dictation audio saved by an earlier run (a
    /// failed take, or one cut off by Quit or a crash) and keeps longer ones.
    /// Launch never asks about any of it.
    func purgeLeftoverStoppedAudio()
}

@MainActor
enum AppLaunchSteps {
    enum Step: String, CaseIterable {
        case leftoverStoppedAudioCleanup = "leftover_stopped_audio_cleanup"
    }

    /// Steps run after the dictation overlay is set up, in order.
    static let afterOverlaySetup: [Step] = [.leftoverStoppedAudioCleanup]

    /// Runs `afterOverlaySetup` and returns the steps it ran.
    @discardableResult
    static func runAfterOverlaySetup(dictation: AppLaunchDictationHost) -> [Step] {
        for step in afterOverlaySetup {
            switch step {
            case .leftoverStoppedAudioCleanup:
                dictation.purgeLeftoverStoppedAudio()
            }
        }
        return afterOverlaySetup
    }
}
