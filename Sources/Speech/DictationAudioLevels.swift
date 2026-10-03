// DictationAudioLevels.swift
// The live dictation meter reading for the Notch island's waveform.
//
// It ticks ~25-30 times a second while recording. It lives on its own small
// owner, held by STTRouter as a `let` (and handed to ParakeetEngine, which
// produces the readings), so a tick never fires STTRouter's
// `objectWillChange`. The Settings shell and onboarding observe the whole
// router; when the level was a @Published property on it, every tick
// re-rendered the window behind the dictation, Today page included. The
// overlay subscribes to `readings` directly. Same shape as the meeting's
// MeetingAudioLevels.

import Combine
import Foundation

@MainActor
final class DictationAudioLevels {
    private let subject = CurrentValueSubject<DictationAudioLevel, Never>(.silent)

    /// Every reading, in order, sent synchronously from `update(_:)` on the
    /// main actor (so a subscriber needs no hop of its own). A new
    /// subscriber gets the current reading first.
    var readings: AnyPublisher<DictationAudioLevel, Never> {
        subject.eraseToAnyPublisher()
    }

    var current: DictationAudioLevel { subject.value }

    func update(_ reading: DictationAudioLevel) {
        subject.send(reading)
    }
}
