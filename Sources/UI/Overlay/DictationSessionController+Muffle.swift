// DictationSessionController+Muffle.swift
// "Muffle other audio while dictating": engage while the dictation mic is
// open, fade back as soon as it closes. The rules live in
// DictationMufflePolicy; the audio work lives in DictationAudioMuffler.

import Combine
import Foundation

extension DictationSessionController {
    /// Follows the mic, not `isDictating`: `isDictating` stays true through
    /// transcription and paste, and flips true again at the stop-finalization
    /// readmissions that never reopen the mic. Music should come back the
    /// moment the user stops talking.
    func makeDictationMuffleSubscription(appState: TranscriptedAppState) -> AnyCancellable {
        appState.sttRouter.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] micOpen in
                self?.updateDictationMuffle(micOpen: micOpen)
            }
    }

    func updateDictationMuffle(micOpen: Bool) {
        guard micOpen, isDictating, let appState else {
            DictationAudioMuffler.shared.release()
            return
        }
        let enabled = DictationMufflePreferences.isEnabled()
        guard enabled else { return }
        DictationAudioMuffler.shared.engage(
            enabled: enabled,
            meetingRecording: appState.meetingSession.isRecording,
            dictatingFromSharedMeetingMic: appState.sttRouter.isRecordingFromSharedMeetingMic,
            voiceProcessingRequested: MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
        )
    }
}
