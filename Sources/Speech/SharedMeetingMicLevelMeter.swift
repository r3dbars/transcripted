@preconcurrency import AVFoundation
import Foundation

/// Dictation's waveform level while it borrows an active meeting's mic.
///
/// The meeting publishes its own mic level every `Audio.levelPublishInterval`
/// (0.15 s) with its own scaling. Feeding that to the dictation island made the
/// waveform move about 3x slower than normal dictation while a meeting
/// recorded. This meters the relayed buffers themselves with
/// `DictationAudioLevelMeter` at `TranscriptedConstants.audioMeteringInterval`,
/// the same cadence and scale as the engine and pinned-mic paths.
///
/// The meeting's engine tap hands over ~4096-frame buffers (~85 ms at 48 kHz)
/// against dictation's 1024-frame tap, so metering one level per buffer would
/// still move at ~12 Hz. A buffer longer than the interval is split into
/// about-interval-long windows, each with its own level and a delay from the
/// buffer's arrival, so the island steps at roughly dictation's pace. The
/// waveform trails the audio by up to one buffer, same as it always did.
///
/// `levels(for:)` runs on MeetingCaptureBridge's off-tap relay queue
/// (Core's host PCM fan-out), never the CoreAudio real-time thread, so the
/// lock here is fine. `begin`/`end` are called from `@MainActor`.
final class SharedMeetingMicLevelMeter: @unchecked Sendable {
    struct Reading: Equatable {
        let level: Float
        let session: UInt64
        /// How long after the buffer arrived to show this level.
        let delay: TimeInterval
    }

    private let lock = NSLock()
    private let interval: TimeInterval
    private let now: () -> CFAbsoluteTime
    private var isActive = false
    private var session: UInt64 = 0
    private var lastPublishedAt: CFAbsoluteTime?

    init(
        interval: TimeInterval = TranscriptedConstants.audioMeteringInterval,
        now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        self.interval = interval
        self.now = now
    }

    func begin() {
        lock.withLock {
            session &+= 1
            isActive = true
            lastPublishedAt = nil
        }
    }

    func end() {
        lock.withLock {
            session &+= 1
            isActive = false
            lastPublishedAt = nil
        }
    }

    /// The levels to show for this buffer, in order: empty when the meter is
    /// idle, or for a short buffer whose last reading is younger than
    /// `interval`. The first buffer after `begin()` is always due, so the
    /// island moves right away.
    func levels(for buffer: AVAudioPCMBuffer) -> [Reading] {
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, sampleRate > 0, interval > 0 else { return [] }
        let windowCount = max(1, Int((Double(frameCount) / sampleRate / interval).rounded()))

        let currentSession: UInt64? = lock.withLock {
            guard isActive else { return nil }
            let timestamp = now()
            // A buffer split into windows fills its own span, so it is always
            // due; the throttle only coalesces buffers shorter than a window.
            if windowCount == 1, let lastPublishedAt, timestamp - lastPublishedAt <= interval { return nil }
            lastPublishedAt = timestamp
            return session
        }
        guard let currentSession else { return [] }

        let framesPerWindow = frameCount / windowCount
        return (0..<windowCount).map { index in
            let start = index * framesPerWindow
            let end = index == windowCount - 1 ? frameCount : start + framesPerWindow
            return Reading(
                level: DictationAudioLevelMeter.normalizedLevel(from: buffer, frames: start..<end),
                session: currentSession,
                delay: Double(start) / sampleRate
            )
        }
    }

    /// False once the borrow that produced `session` has ended or been
    /// replaced, so a reading still hopping to the main actor can't land on
    /// the next dictation.
    func isCurrent(session candidate: UInt64) -> Bool {
        lock.withLock { isActive && session == candidate }
    }
}
