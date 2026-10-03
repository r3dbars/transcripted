// DictationSessionController+Muffle.swift
// "Muffle other audio while dictating": engage once the dictation mic is
// open, open the music back up as soon as the stop is admitted. The rules
// live in DictationMufflePolicy; the audio work lives in DictationAudioMuffler.

import Combine
import Foundation

extension DictationSessionController {
    /// Follows the mic, not `isDictating`: `isDictating` stays true through
    /// transcription and paste, and flips true again at the stop-finalization
    /// readmissions that never reopen the mic.
    ///
    /// No `receive(on:)` hop: `isRecording` is set on the main actor, and
    /// engaging only snapshots main-actor state and hands it to the muffler's
    /// queue. Hopping would park the engage behind the rest of the take's
    /// start work, which delayed the muffle by ~130 ms (p50) in testing.
    func makeDictationMuffleSubscription(appState: TranscriptedAppState) -> AnyCancellable {
        appState.sttRouter.$isRecording
            .removeDuplicates()
            .sink { [weak self] micOpen in
                // @Published emits in willSet, so use `micOpen` and never
                // re-read isRecording here.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.updateDictationMuffle(micOpen: micOpen) }
                } else {
                    DispatchQueue.main.async { self?.updateDictationMuffle(micOpen: micOpen) }
                }
            }
    }

    func updateDictationMuffle(micOpen: Bool) {
        guard micOpen, isDictating, let appState else {
            DictationAudioMuffler.shared.micClosed()
            return
        }
        DictationAudioMuffler.shared.micOpened(DictationMuffleContext(
            enabled: DictationMufflePreferences.isEnabled(),
            meetingRecording: appState.meetingSession.isRecording,
            dictatingFromSharedMeetingMic: appState.sttRouter.isRecordingFromSharedMeetingMic,
            voiceProcessingRequested: MicrophoneProcessingPreferences.isVoiceProcessingEnabled(),
            automatedLaunch: AutomatedLaunchEnvironment.isActive()
        ))
    }

    /// The stop is admitted, so the user is done talking: bring the music
    /// back now instead of after the mic finishes draining, which can take a
    /// few hundred milliseconds.
    func releaseDictationMuffleForStop() {
        DictationAudioMuffler.shared.micClosed()
    }
}
