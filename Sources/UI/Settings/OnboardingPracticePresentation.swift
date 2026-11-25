import Foundation

/// What a setup practice screen says. The takes are real dictations through
/// the normal key, island and paste-back; this only names where the person is.
/// `OnboardingPracticeStage` renders it.
struct OnboardingPracticePresentation: Equatable {
    enum Kind: Equatable {
        /// The first take: hold the key (or tap it, in tap-to-toggle mode).
        case first
        /// The second take, hands-free: tap, talk, tap.
        case handsFree
    }

    enum Phase: Equatable {
        /// The key rides an Accessibility event tap, so it can't work yet.
        case needsPasteAccess
        /// Dictation shortcuts are turned off in Settings.
        case keyOff
        /// The voice model is still downloading (progress 0...1 when known).
        case downloading(progress: Double?)
        case loading
        case failed
        /// Ready for a take.
        case ready
        case listening
        case transcribing
        /// The take ended without words.
        case heardNothing
        case done
    }

    let headline: String
    let instruction: String
    let status: String?
    /// The status is something happening now or just worked (green dot/check).
    let statusIsLive: Bool
    let showsProgress: Bool
    let progress: Double?

    static func phase(
        accessibilityGranted: Bool,
        keyEnabled: Bool,
        modelState: ParakeetModelState,
        isRecording: Bool,
        isTranscribing: Bool,
        takeDone: Bool,
        heardNothing: Bool
    ) -> Phase {
        if takeDone { return .done }
        if !accessibilityGranted { return .needsPasteAccess }
        if !keyEnabled { return .keyOff }
        if isRecording { return .listening }
        if isTranscribing { return .transcribing }
        switch modelState {
        case .downloading(let progress):
            return .downloading(progress: progress > 0 ? min(1, progress) : nil)
        case .loading:
            return .loading
        case .failed:
            return .failed
        case .notLoaded, .cached, .ready:
            break
        }
        return heardNothing ? .heardNothing : .ready
    }

    static func make(
        kind: Kind,
        phase: Phase,
        keyDisplay: String,
        keyBehavior: DictationKeyBehavior
    ) -> OnboardingPracticePresentation {
        let headline: String
        let instruction: String
        switch kind {
        case .first:
            headline = "Now try it"
            instruction = keyBehavior == .tapToToggle
                ? "Tap \(keyDisplay), say anything, then tap it again."
                : "Hold \(keyDisplay) and say anything. Let go to paste."
        case .handsFree:
            headline = "Now hands-free"
            instruction = "Tap \(keyDisplay) once and talk. Tap it again when you're done."
        }

        let status: String?
        var live = false
        var showsProgress = false
        var progress: Double?
        switch phase {
        case .needsPasteAccess:
            status = "Your key needs paste access first. Allow it, or skip for now."
        case .keyOff:
            status = "Your dictation key is off. Turn it on in Settings, or skip for now."
        case .downloading(let value):
            if let value {
                status = "Getting the voice model ready · \(Int((value * 100).rounded()))%"
            } else {
                status = "Getting the voice model ready"
            }
            showsProgress = true
            progress = value
        case .loading:
            status = "Loading the voice model…"
            showsProgress = true
        case .failed:
            status = "The voice model didn't load. Skip for now and try again from Settings."
        case .ready:
            status = nil
        case .listening:
            status = "Listening…"
            live = true
        case .transcribing:
            status = "Writing it down…"
            live = true
        case .heardNothing:
            status = "Didn't catch that. Try again, a little closer to the mic."
        case .done:
            status = kind == .first
                ? "That's it. It works the same in every app."
                : "Nice. Use whichever feels right."
            live = true
        }

        return OnboardingPracticePresentation(
            headline: headline,
            instruction: instruction,
            status: status,
            statusIsLive: live,
            showsProgress: showsProgress,
            progress: progress
        )
    }
}
