// AppLaunchSteps.swift
// Launch work the app delegate runs once its controllers are wired. Kept as a
// list so tests can check each step is still there and still runs.

/// The dictation side of launch. `DictationSessionController` conforms.
@MainActor
protocol AppLaunchDictationHost: AnyObject {
    /// Offers to finish a dictation whose audio was saved at Stop but never
    /// transcribed (the app quit or crashed in between).
    func presentPendingStoppedAudioRecoveryIfNeeded()
}

@MainActor
enum AppLaunchSteps {
    enum Step: String, CaseIterable {
        case pendingStoppedAudioRecovery = "pending_stopped_audio_recovery"
    }

    /// Steps run after the dictation overlay is set up, in order.
    static let afterOverlaySetup: [Step] = [.pendingStoppedAudioRecovery]

    /// Runs `afterOverlaySetup` and returns the steps it ran.
    @discardableResult
    static func runAfterOverlaySetup(dictation: AppLaunchDictationHost) -> [Step] {
        for step in afterOverlaySetup {
            switch step {
            case .pendingStoppedAudioRecovery:
                dictation.presentPendingStoppedAudioRecoveryIfNeeded()
            }
        }
        return afterOverlaySetup
    }
}
