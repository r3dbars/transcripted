// MeetingAudioLevels.swift
// Live mic and system-audio meter levels for the meeting overlay.
//
// These tick several times a second while recording. They live on their own
// small ObservableObject, owned by MeetingSessionController as a `let`, so a
// level tick never fires the controller's `objectWillChange`. Anything that
// observes the whole controller (the Settings/Home window) stays quiet; the
// overlay subscribes to `$micLevel` / `$systemLevel` directly.

import Combine
import Foundation

@MainActor
final class MeetingAudioLevels: ObservableObject {
    @Published private(set) var micLevel: Float = 0       // mic-only level
    @Published private(set) var systemLevel: Float = 0    // system audio level

    func updateMic(_ level: Float) {
        micLevel = level
    }

    func updateSystem(_ level: Float) {
        systemLevel = level
    }
}
