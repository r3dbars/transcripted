import AppKit
import Combine

extension TranscriptedAppDelegate {
    /// Next Sentence's voice (holding fn, or saying a change) runs on Transcripted's own dictation.
    func wireNextSentenceVoice() {
        // Next Sentence's voice changes: a hand-off take on Transcripted's own dictation, which gives the
        // words back instead of pasting them and finishes quietly. It never starts over or stops the
        // person's own dictation. The card is the listening UI, so the notch stays hidden; the words
        // still save to Dictations.
        appState.nextSentence.startDictation = { [weak self] in
            self?.sessionController.startHandOffDictation(sourceApp: NSWorkspace.shared.frontmostApplication) ?? false
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
            let session = self.sessionController
            // Already over (the dictation key or the session cap stopped it): hand the words over now.
            if let text = session.claimHandOffText() {
                deliver(text)
                return nil
            }
            let watch = session.$handOffText
                .dropFirst()
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { _ in MainActor.assumeIsolated { session.claimHandOffText().map(deliver) } }
            session.stopHandOffDictation()
            return watch
        }
        appState.nextSentence.cancelDictation = { [weak self] in
            self?.sessionController.cancelHandOffDictation()
        }
        // A take that ended without the card asking: the card finishes listening as if they'd let go.
        sessionController.$handOffText
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.appState.nextSentence.dictationEndedElsewhere() } }
            .store(in: &statusItemSubscriptions)
    }
}
