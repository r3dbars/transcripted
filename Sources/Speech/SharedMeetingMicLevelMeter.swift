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
/// `levelIfDue(for:)` runs on MeetingCaptureBridge's off-tap relay queue
/// (Core's host PCM fan-out), never the CoreAudio real-time thread, so the
/// lock here is fine. `begin`/`end` are called from `@MainActor`.
final class SharedMeetingMicLevelMeter: @unchecked Sendable {
    struct Reading: Equatable {
        let level: Float
        let session: UInt64
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

    /// A reading when this buffer is due for the meter, nil when the meter is
    /// idle or the last reading is younger than `interval`. The first buffer
    /// after `begin()` is always due, so the island moves right away.
    func levelIfDue(for buffer: AVAudioPCMBuffer) -> Reading? {
        let currentSession: UInt64? = lock.withLock {
            guard isActive else { return nil }
            let timestamp = now()
            if let lastPublishedAt, timestamp - lastPublishedAt <= interval { return nil }
            lastPublishedAt = timestamp
            return session
        }
        guard let currentSession else { return nil }
        return Reading(level: DictationAudioLevelMeter.normalizedLevel(from: buffer), session: currentSession)
    }

    /// False once the borrow that produced `session` has ended or been
    /// replaced, so a reading still hopping to the main actor can't land on
    /// the next dictation.
    func isCurrent(session candidate: UInt64) -> Bool {
        lock.withLock { isActive && session == candidate }
    }
}
