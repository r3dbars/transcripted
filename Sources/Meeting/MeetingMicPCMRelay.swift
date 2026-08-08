@preconcurrency import AVFoundation
import Foundation

/// Stable handler switch behind TranscriptedCore's bounded off-tap FIFO.
/// Core installs one callback before capture starts; borrowed-mic dictation
/// can then opt in and out without replacing that callback while CoreAudio is
/// running. Do not add another queue here: a second bounded queue would either
/// duplicate memory or silently coalesce already-admitted speech.
final class MeetingMicPCMRelay: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer) -> Void

    private let lock = NSLock()
    private var dictationHandler: Handler?

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = dictationHandler
        lock.unlock()
        handler?(buffer)
    }

    func setDictationHandler(_ handler: Handler?) {
        lock.lock()
        dictationHandler = handler
        lock.unlock()
    }
}
