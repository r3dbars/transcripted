import Foundation

/// The three first-run steps, in order: welcome, permissions, done.
enum OnboardingStepKind: Hashable {
    case welcome
    case permissions
    case done

    var analyticsID: String {
        switch self {
        case .welcome:
            return "welcome"
        case .permissions:
            return "permissions"
        case .done:
            return "done"
        }
    }
}

/// What the onboarding footer offers on a step. One path, no branching:
/// the microphone is the only permission that gates progress, and once macOS
/// won't ask for it again (the person picked Don't Allow), setup offers a skip
/// instead of a dead end. `PermissionsOnboardingView` reads this; nothing here
/// touches permissions itself.
struct OnboardingNavigation: Equatable {
    static let steps: [OnboardingStepKind] = [.welcome, .permissions, .done]

    let step: OnboardingStepKind
    let microphoneGranted: Bool
    let microphoneBlocked: Bool
    let skippedMicrophone: Bool

    static func step(at index: Int) -> OnboardingStepKind {
        steps[min(max(index, 0), steps.count - 1)]
    }

    var hasRequiredPermissions: Bool {
        FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: microphoneGranted)
    }

    var canFinishSetup: Bool {
        hasRequiredPermissions || skippedMicrophone
    }

    var primaryTitle: String {
        switch step {
        case .welcome:
            return "Set Up"
        case .permissions:
            return "Continue"
        case .done:
            // "Open Transcripted" read like a second app launch; this just
            // closes setup and shows the menu bar.
            return "Done"
        }
    }

    var primaryDisabled: Bool {
        switch step {
        case .welcome:
            return false
        case .permissions:
            return !hasRequiredPermissions
        case .done:
            return !canFinishSetup
        }
    }

    /// Offered only once macOS won't ask for the microphone again.
    var secondaryTitle: String? {
        guard step == .permissions, microphoneBlocked, !microphoneGranted else { return nil }
        return "Skip for now"
    }

    /// Whether the skip button may act right now.
    var canSkipMicrophone: Bool {
        step == .permissions && !microphoneGranted
    }
}
