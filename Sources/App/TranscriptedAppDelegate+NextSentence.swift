import AppKit
import Combine

extension TranscriptedAppDelegate {
    /// Next Sentence's voice (holding fn, or saying a change) runs on Transcripted's own dictation.
    func wireNextSentenceVoice() {
        // Next Sentence's voice changes: Transcripted's own dictation, stopped without pasting
        // anywhere. The card takes what was said once it's transcribed.
        // The card is the listening UI, so this dictation's notch stays hidden; it still saves to Dictations.
        appState.nextSentence.startDictation = { [weak self] in
            guard let self else { return }
            self.overlayController.quiet = true
            self.sessionController.startDictation(sourceApp: NSWorkspace.shared.frontmostApplication, trigger: .menu)
        }
        // The card's edge glow follows the microphone (RMS is small, so lift quiet speech into view).
        appState.sttRouter.audioLevels.readings
            .sink { [weak self] reading in
                self?.appState.nextSentence.setVoiceLevel(CGFloat(min(1, 2 * reading.level.squareRoot())))
            }
            .store(in: &statusItemSubscriptions)
        // And the card shows the words as they're spoken, from dictation's live preview.
        LiveDictationCaptions.shared.$preview
            .sink { [weak self] preview in
                let words = [preview.settled, preview.tentative].filter { !$0.isEmpty }.joined(separator: " ")
                self?.appState.nextSentence.setLiveWords(words)
            }
            .store(in: &statusItemSubscriptions)
        appState.nextSentence.finishDictation = { [weak self] deliver in
            guard let self else { return nil }
            let watch = self.sessionController.$lastCompletedText
                .dropFirst()
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { text in MainActor.assumeIsolated { deliver(text) } }
            self.sessionController.stopDictationAndPaste(trigger: .menu, autoPaste: false)
            return watch
        }
    }
}
