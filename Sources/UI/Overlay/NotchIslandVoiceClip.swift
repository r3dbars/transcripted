// NotchIslandVoiceClip.swift
// How one "Who spoke?" row plays its voice: the clip file Core saved (the
// island, and saved people on the Speakers page), a window of a meeting's kept
// audio (a voice on the Speakers page that never got its own clip), or
// nothing to play.

import Foundation

enum NotchIslandVoiceClip: Equatable {
    case file(URL)
    case window(SpeakerRetainedAudioSample)
    case none

    var isPlayable: Bool { self != .none }

    @MainActor
    func play() {
        switch self {
        case .file(let url): SpeakerClipPlayback.play(url)
        case .window(let sample): SpeakerClipPlayback.shared.play(sample)
        case .none: break
        }
    }

    @MainActor
    var isPlaying: Bool {
        switch self {
        case .file(let url): return SpeakerClipPlayback.isPlaying(url)
        case .window(let sample): return SpeakerClipPlayback.shared.isPlaying(sample)
        case .none: return false
        }
    }
}
