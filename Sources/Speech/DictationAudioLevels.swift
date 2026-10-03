// DictationAudioLevels.swift
// The live dictation mic level for the island meter.
//
// It ticks about 20 times a second while recording. It lives on its own small
// ObservableObject, owned by STTRouter as a `let`, so a level tick never fires
// the router's `objectWillChange`. Anything that observes the whole router
// (the Settings/Home window and onboarding) stays quiet during a take; the
// overlay subscribes to `$level` directly. Same shape as MeetingAudioLevels.

import Combine
import Foundation

@MainActor
final class DictationAudioLevels: ObservableObject {
    @Published private(set) var level: Float = 0

    func update(_ level: Float) {
        self.level = level
    }
}
