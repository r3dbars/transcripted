// NotchIslandController+DictationBars.swift
// The dictation waveform in the wing. Meter readings only record what the
// next bar shows; a display link steps the bars at one even pace while a
// dictation listens on screen (`NotchIslandLevelScroller`), so a busy main
// thread can't freeze them and then jump them several bars at once.

import AppKit
import QuartzCore

extension NotchIslandController {
    func updateDictationLevel(_ reading: DictationAudioLevel) {
        guard isShown, dictation?.phase == .listening else { return }
        islandView?.receiveDictationLevel(reading, at: CACurrentMediaTime())
    }

    /// The bars' clock runs only while a dictation listens on screen.
    func updateDictationBarsClock() {
        guard isShown, dictation?.phase == .listening, let islandView else {
            dictationBarsClock.stop()
            return
        }
        guard !dictationBarsClock.isRunning else { return }
        dictationBarsClock.onFrame = { [weak self] time, frameDuration in
            self?.islandView?.advanceDictationBars(to: time, frameDuration: frameDuration)
        }
        dictationBarsClock.start(on: islandView)
    }
}

/// Calls `onFrame` once per display frame, on the main thread, while it runs.
@MainActor
final class NotchIslandFrameClock: NSObject {
    var onFrame: ((_ time: CFTimeInterval, _ frameDuration: CFTimeInterval) -> Void)?
    private var link: CADisplayLink?

    var isRunning: Bool { link != nil }

    /// Ticks with the display `view` is on.
    func start(on view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        // 60 or 120 a second: a whole number of frames per 50 ms bar, so
        // the bars keep an even pace.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp, link.targetTimestamp - link.timestamp)
    }
}
