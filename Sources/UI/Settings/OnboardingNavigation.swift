import Foundation

/// First-run steps, in order. One ask per screen, then two real dictations,
/// then the promise and Done. Calendar, agent connect and file import are not
/// setup steps; they live where they always did (Settings › General, Agent,
/// Transcribe a file).
///
/// Paste access comes before the first take because the dictation key rides
/// an event tap that needs Accessibility: without it the key does nothing.
enum OnboardingStepKind: Hashable, CaseIterable {
    case welcome
    case microphone
    case accessibility
    /// First real dictation (hold the key, or tap it in tap-to-toggle mode).
    case tryIt
    /// Second real dictation, hands-free (tap, talk, tap). Only with Hold or tap.
    case tryHandsFree
    case systemAudio
    case promise
    case done

    var analyticsID: String {
        switch self {
        case .welcome: return "welcome"
        case .microphone: return "microphone"
        case .accessibility: return "accessibility"
        case .tryIt: return "try_it"
        case .tryHandsFree: return "try_hands_free"
        case .systemAudio: return "system_audio"
        case .promise: return "promise"
        case .done: return "done"
        }
    }

    var isPractice: Bool { self == .tryIt || self == .tryHandsFree }
}

/// What the onboarding footer offers on a step, and which steps apply right
/// now. The microphone is the only permission that gates finishing; once
/// macOS won't ask for it again (Don't Allow), setup offers a skip instead of
/// a dead end. `PermissionsOnboardingView` reads this; nothing here touches
/// permissions itself.
struct OnboardingNavigation: Equatable {
    static let steps: [OnboardingStepKind] = [
        .welcome, .microphone, .accessibility, .tryIt, .tryHandsFree, .systemAudio, .promise, .done,
    ]

    enum PrimaryAction: Equatable {
        case advance
        case requestMicrophone
        case requestAccessibility
        case requestSystemAudio
        case finish
    }

    enum SecondaryAction: Equatable {
        /// Jumps to Done without the microphone (only after Don't Allow).
        case skipMicrophone
        /// Moves on without this step.
        case skip
    }

    let step: OnboardingStepKind
    var microphoneGranted = false
    var microphoneBlocked = false
    var skippedMicrophone = false
    var accessibilityGranted = false
    /// Dictation shortcuts are on (a forced rerun may find them off).
    var dictationKeyEnabled = true
    var keyBehavior: DictationKeyBehavior = .holdOrTap
    var tryItDone = false
    var tryHandsFreeDone = false
    var systemAudioVerified = false
    var systemAudioChecking = false
    /// `TranscriptedPermissionKind.SystemAudioOnboardingPresentation.actionTitle`.
    var systemAudioActionTitle = "Grant"

    static func step(at index: Int) -> OnboardingStepKind {
        steps[min(max(index, 0), steps.count - 1)]
    }

    static func index(of step: OnboardingStepKind) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    var hasRequiredPermissions: Bool {
        FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: microphoneGranted)
    }

    var canFinishSetup: Bool {
        hasRequiredPermissions || skippedMicrophone
    }

    /// Whether a step is part of this run. Practice needs the microphone and
    /// the dictation key; the hands-free take follows a finished first take,
    /// and only when the key does both hold and tap.
    func isShown(_ candidate: OnboardingStepKind) -> Bool {
        switch candidate {
        case .welcome, .promise, .done:
            return true
        case .microphone:
            return true
        case .accessibility, .systemAudio:
            return !skippedMicrophone
        case .tryIt:
            return !skippedMicrophone && microphoneGranted && dictationKeyEnabled
        case .tryHandsFree:
            return isShown(.tryIt) && tryItDone && keyBehavior == .holdOrTap
        }
    }

    /// The next shown step after this one, or nil on Done.
    var nextStep: OnboardingStepKind? {
        let start = Self.index(of: step) + 1
        return Self.steps.dropFirst(start).first(where: isShown)
    }

    /// The previous shown step, or nil on Welcome.
    var previousStep: OnboardingStepKind? {
        let end = Self.index(of: step)
        return Self.steps.prefix(end).last(where: isShown)
    }

    var primaryAction: PrimaryAction {
        switch step {
        case .welcome, .promise:
            return .advance
        case .microphone:
            return microphoneGranted ? .advance : .requestMicrophone
        case .accessibility:
            return accessibilityGranted ? .advance : .requestAccessibility
        case .tryIt, .tryHandsFree:
            return accessibilityGranted ? .advance : .requestAccessibility
        case .systemAudio:
            return systemAudioVerified ? .advance : .requestSystemAudio
        case .done:
            return .finish
        }
    }

    var primaryTitle: String {
        switch step {
        case .welcome:
            return "Set up"
        case .microphone:
            if microphoneGranted { return "Continue" }
            return microphoneBlocked ? "Open System Settings" : "Allow microphone"
        case .accessibility:
            return accessibilityGranted ? "Continue" : "Allow paste access"
        case .tryIt, .tryHandsFree:
            return accessibilityGranted ? "Continue" : "Allow paste access"
        case .systemAudio:
            if systemAudioVerified { return "Continue" }
            switch systemAudioActionTitle {
            case "Checking…": return "Checking…"
            case "Check": return "Check again"
            default: return "Allow call audio"
            }
        case .promise:
            return "Continue"
        case .done:
            // Done closes setup and opens Today in the main window.
            return "Done"
        }
    }

    var primaryDisabled: Bool {
        switch step {
        case .welcome, .microphone, .accessibility, .promise:
            return false
        case .tryIt:
            return accessibilityGranted && !tryItDone
        case .tryHandsFree:
            return accessibilityGranted && !tryHandsFreeDone
        case .systemAudio:
            return systemAudioChecking
        case .done:
            return !canFinishSetup
        }
    }

    var secondaryAction: SecondaryAction? {
        switch step {
        case .microphone:
            return microphoneBlocked && !microphoneGranted ? .skipMicrophone : nil
        case .accessibility:
            return accessibilityGranted ? nil : .skip
        case .tryIt:
            return tryItDone ? nil : .skip
        case .tryHandsFree:
            return tryHandsFreeDone ? nil : .skip
        case .systemAudio:
            return systemAudioVerified || systemAudioChecking ? nil : .skip
        case .welcome, .promise, .done:
            return nil
        }
    }

    var secondaryTitle: String? {
        switch secondaryAction {
        case .skipMicrophone, .skip:
            return step.isPractice ? "Skip" : "Skip for now"
        case nil:
            return nil
        }
    }

    /// Whether the microphone skip may act right now.
    var canSkipMicrophone: Bool {
        step == .microphone && !microphoneGranted
    }

    /// "Step 2 of 4" across the asks and the takes, or nil on the welcome,
    /// promise and done screens. Call audio is optional and says so instead.
    var progressLabel: String? {
        switch step {
        case .welcome, .promise, .done:
            return nil
        case .systemAudio:
            return "Optional"
        case .microphone, .accessibility, .tryIt, .tryHandsFree:
            // Count the hands-free take as soon as it can come, so the total
            // doesn't grow after the first take.
            var counting = self
            counting.tryItDone = true
            let counted: [OnboardingStepKind] = [.microphone, .accessibility, .tryIt, .tryHandsFree]
                .filter(counting.isShown)
            guard let position = counted.firstIndex(of: step) else { return nil }
            return "Step \(position + 1) of \(counted.count)"
        }
    }
}
