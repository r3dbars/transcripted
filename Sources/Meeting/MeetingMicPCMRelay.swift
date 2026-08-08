@preconcurrency import AVFoundation
import Foundation

/// Stable, off-tap fan-out for the meeting microphone stream. Core installs
/// one callback before capture starts; borrowed-mic dictation can then opt in
/// and out without replacing that callback while CoreAudio is running.
final class MeetingMicPCMRelay: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(
        label: "com.transcripted.meeting-mic-pcm-relay",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var dictationHandler: Handler?
    private var pendingBuffer: AVAudioPCMBuffer?
    private var drainScheduled = false

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        // Keep at most one waiting buffer plus the one being handled. If the
        // optional dictation consumer stalls, newer audio replaces the pending
        // buffer instead of creating an unlimited collection of queue blocks.
        lock.lock()
        guard dictationHandler != nil else {
            lock.unlock()
            return
        }
        pendingBuffer = buffer
        let shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    func setDictationHandler(_ handler: Handler?) {
        lock.lock()
        dictationHandler = handler
        if handler == nil {
            pendingBuffer = nil
        }
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let buffer = pendingBuffer,
                  let handler = dictationHandler else {
                pendingBuffer = nil
                drainScheduled = false
                lock.unlock()
                return
            }
            pendingBuffer = nil
            lock.unlock()

            handler(buffer)
        }
    }

    var pendingBufferCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBuffer == nil ? 0 : 1
    }
}
