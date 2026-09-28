import Foundation

/// What a dictation take that came back with no text should do.
///
/// `DictationSessionController.stopDictationAndPaste` asks this once it knows
/// why the text is empty, then runs the matching UI; tests call it directly.
/// First match wins:
///
/// 1. A quick, too-short press is a mis-tap: close like a cancel, no error.
/// 2. No speech worth keeping: show the no-speech note, then drop the audio.
/// 3. Probably a wrong-language guess with text held back: offer Paste Anyway,
///    and keep the audio in case the guess was wrong.
/// 4. The audio is saved: say why and offer to transcribe it again. Audio the
///    model heard nothing in also keeps its launch reminder.
/// 5. Audio that needs recovery but has no saved WAV: offer the no-paste
///    checkpoint retry instead of calling it empty speech.
/// 6. Otherwise: just say why.
enum DictationEmptyTranscriptPolicy {
    enum Action: Equatable {
        case closeLikeCancel
        case showNoSpeechAndDismiss
        case offerPasteAnyway
        case offerSavedRecording(remindAtLaunch: Bool)
        case offerCheckpointRetry
        case showMessage
    }

    struct Decision: Equatable {
        var action: Action
        /// Friction telemetry counts a mis-tap as cancelled, everything else as a give-up.
        var countsAsCancelled: Bool
        /// Delete the stopped-audio checkpoint once the take is closed.
        var discardsSavedRecording: Bool
    }

    static func decide(
        reason: DictationEmptyTranscriptionReason,
        pressDuration: TimeInterval,
        hasHeldBackText: Bool,
        hasSavedRecording: Bool
    ) -> Decision {
        let isMisTap = reason.isAccidentalStart(pressDuration: pressDuration)
        let action: Action
        if isMisTap {
            action = .closeLikeCancel
        } else if reason.shouldDiscardStoppedAudioRecovery {
            action = .showNoSpeechAndDismiss
        } else if reason == .otherLanguage, hasHeldBackText {
            action = .offerPasteAnyway
        } else if hasSavedRecording {
            action = .offerSavedRecording(remindAtLaunch: reason == .audioNeedsRecovery)
        } else if reason == .audioNeedsRecovery {
            action = .offerCheckpointRetry
        } else {
            action = .showMessage
        }
        return Decision(
            action: action,
            countsAsCancelled: isMisTap,
            discardsSavedRecording: reason.shouldDiscardStoppedAudioRecovery
        )
    }
}
