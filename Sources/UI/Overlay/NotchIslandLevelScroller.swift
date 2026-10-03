// NotchIslandLevelScroller.swift
// The dictation waveform's motion, kept apart from when readings arrive.
//
// Readings come about 25 times a second from the capture queue, one hop to
// the main actor, so a busy main thread hands them over in bunches. The old
// bars shifted once per reading: a stall froze them and the bunch after it
// jumped them several bars at once. Here the bars step on the display's
// clock (NotchIslandController runs a display link while a dictation listens):
// one bar per `stepInterval`, at most one step per frame, and a late frame
// steps once and starts the clock again from there instead of catching up.
// Readings only decide what the next bar shows. Foundation only, so the fast
// tests drive it with an injected clock.

import Foundation

struct NotchIslandLevelScroller {
    /// One bar per interval: the meter's old nominal pace, about 20 a second.
    static let stepInterval: TimeInterval = TranscriptedConstants.audioMeteringInterval
    /// Share of the way a bar rises toward a louder reading in one step.
    static let attack: Float = 0.8
    /// Share of the way it falls toward a quieter one.
    static let release: Float = 0.5
    /// With no new reading (its hop is late), the bars hold this long, then
    /// fall to rest.
    static let holdTime: TimeInterval = 0.25

    /// Raw meter levels in 0...1, oldest first, newest last (the right end).
    private(set) var levels: [Float]
    /// The loudest of the readings since the last step.
    private var pending: (level: Float, peak: Float)?
    private var lastReadingAt: TimeInterval?
    private var nextStepAt: TimeInterval?

    init(count: Int) {
        levels = Array(repeating: 0, count: max(1, count))
    }

    /// A meter reading. It changes nothing on screen until the next step.
    mutating func receive(_ reading: DictationAudioLevel, at time: TimeInterval) {
        let level = Self.clamped(reading.level)
        let peak = max(level, Self.clamped(reading.peak))
        if let pending {
            self.pending = (max(pending.level, level), max(pending.peak, peak))
        } else {
            pending = (level, peak)
        }
        lastReadingAt = time
    }

    /// One display frame at `time`. Steps on the frame nearest each
    /// `stepInterval` boundary, never more than once per frame; the first
    /// frame steps and starts the clock. Returns true when the bars moved.
    mutating func advance(to time: TimeInterval, frameDuration: TimeInterval) -> Bool {
        let halfFrame = max(0, frameDuration) / 2
        if let nextStepAt, time + halfFrame < nextStepAt { return false }
        step(at: time)
        var next = (nextStepAt ?? time) + Self.stepInterval
        // A late frame (the main thread stalled) steps once and the clock
        // starts again here, so the bars never rush to catch up.
        if time + halfFrame >= next { next = time + Self.stepInterval }
        nextStepAt = next
        return true
    }

    /// The newest bar rises fast toward the loudest buffer heard since the
    /// last step (so a short syllable shows at its height) and falls gently
    /// toward their average, which keeps the waveform from flickering.
    private mutating func step(at time: TimeInterval) {
        let current = levels.last ?? 0
        let newest: Float
        if let pending {
            newest = pending.peak > current
                ? current + (pending.peak - current) * Self.attack
                : current + (pending.level - current) * Self.release
        } else if let lastReadingAt, time - lastReadingAt <= Self.holdTime {
            newest = current
        } else {
            newest = current * (1 - Self.release)
        }
        pending = nil
        levels.removeFirst()
        levels.append(newest)
    }

    private static func clamped(_ value: Float) -> Float {
        value.isFinite ? max(0, min(1, value)) : 0
    }
}
