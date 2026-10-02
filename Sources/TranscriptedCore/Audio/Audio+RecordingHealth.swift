import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Recording health: gaps, device-switch and format-rebuild counters,
// mic recovery ownership and segments, the system recovery write hold,
// and the `RecordingHealthInfo` snapshots.
extension Audio {
    /// Simple struct to track audio gaps (sleep/wake, device switches)
    struct AudioGap {
        let start: Date
        let duration: TimeInterval
        let reason: String

        var description: String {
            let durationStr = String(format: "%.1f", duration)
            return "\(reason): \(durationStr)s"
        }
    }

    /// Records a system-audio-side bounded-recovery attempt (SCK restarting
    /// its ScreenCaptureKit stream after a buffer stall or stream stop) into
    /// the SAME counter mic-path device switches use, so system-audio
    /// dropouts count toward `RecordingHealthInfo.captureQuality` instead of
    /// being invisible to it. Wired from `wireSystemAudioStatusPublisher`'s
    /// `recoveryEventPublisher` subscription, which already runs on main.
    func recordSystemAudioDeviceSwitch() {
        // A mic-only recording has no tap; a finished tap's late event must
        // not count against it.
        guard isRecording, currentRecordingCapturesSystemAudio else { return }
        incrementDeviceSwitchCount()
    }

    /// Records a system-audio recovery gap (a reconnect succeeded after
    /// `duration` seconds of stalled/stopped capture), mirroring the mic
    /// path's `AudioGap` entries into the SAME `recordingGaps` array so
    /// system-audio interruptions show up in saved transcript health
    /// metadata the same way mic-side gaps already do.
    ///
    /// This is the metadata half, handled on main. The pad itself is written
    /// by `padSystemAudioGapBeforeNextBuffer` on the capture's own thread, so
    /// the reconnect's first buffer isn't dropped by the hold.
    func appendSystemAudioGap(duration: TimeInterval) {
        // A mic-only recording has no tap; a finished tap's late gap must
        // not count against it.
        guard isRecording, currentRecordingCapturesSystemAudio else { return }
        appendRecordingGap(AudioGap(
            start: Date(timeIntervalSinceNow: -duration),
            duration: duration,
            reason: "System audio reconnect"
        ))
    }

    /// Runs on the thread that sent `.gap`, before the capture hands over
    /// the reconnect's first buffer. Releasing the hold here, rather than
    /// later on main, keeps that buffer (and any after it) from being thrown
    /// away uncounted by the pad (deep review M8). The pad is queued on the
    /// file queue ahead of the buffer's own write. No `isRecording` check:
    /// that flag belongs to main, and the file queue already drops a pad
    /// whose generation no longer owns the system writer.
    func padSystemAudioGapBeforeNextBuffer(duration: TimeInterval) {
        if currentRecordingCapturesSystemAudio {
            enqueueSystemRecoverySilencePad(
                duration: duration,
                generation: recordingSessionGeneration
            )
        }
        releaseSystemRecoveryWriteHold()
    }

    /// Commit recovery artifacts only while the recovery still owns the
    /// current recording generation. The generation lock also blocks a
    /// concurrent stop/start from advancing the session between the check and
    /// the array/journal mutations.
    @discardableResult
    func finalizeMicRecoveryArtifacts(
        gap: AudioGap,
        recoverySegment: MicRecordingSegment?,
        sessionGeneration: UInt64
    ) -> Bool {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        guard recordingSessionGenerationEpoch.snapshot().rawValue == sessionGeneration else { return false }

        appendRecordingGap(gap)
        if let recoverySegment {
            appendMicSegment(recoverySegment)
        }
        recoveryAttemptCount = 0
        return true
    }

    /// List a recovery segment before its tap can write to it, so a Stop
    /// that lands mid-recovery merges the file instead of losing it.
    @discardableResult
    func registerMicRecoverySegment(
        _ segment: MicRecordingSegment,
        sessionGeneration: UInt64
    ) -> Bool {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        guard recordingSessionGenerationEpoch.snapshot().rawValue == sessionGeneration else { return false }

        appendMicSegment(segment)
        return true
    }

    /// Drop a registered recovery segment after the recovery failed. Returns
    /// false when Stop already took the session, which means Stop listed and
    /// owns the file and the caller must not delete it.
    @discardableResult
    func unregisterMicRecoverySegment(
        _ url: URL,
        sessionGeneration: UInt64
    ) -> Bool {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        guard recordingSessionGenerationEpoch.snapshot().rawValue == sessionGeneration else { return false }

        micSegmentsLock.lock()
        _micSegments.removeAll { $0.url == url }
        let segments = _micSegments
        micSegmentsLock.unlock()
        recordingJournal.recordSegments(segments, session: journalSession)
        return true
    }

    /// Commit a recovery whose segment was registered up front: record the
    /// gap, correct the segment's gap to the measured one, reset the streak.
    @discardableResult
    func finalizeRegisteredMicRecoverySegment(
        gap: AudioGap,
        segmentURL: URL,
        sessionGeneration: UInt64
    ) -> Bool {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        guard recordingSessionGenerationEpoch.snapshot().rawValue == sessionGeneration else { return false }

        appendRecordingGap(gap)
        micSegmentsLock.lock()
        _micSegments = _micSegments.map {
            $0.url == segmentURL
                ? MicRecordingSegment(url: $0.url, gapBeforeDuration: gap.duration)
                : $0
        }
        let segments = _micSegments
        micSegmentsLock.unlock()
        recordingJournal.recordSegments(segments, session: journalSession)
        recoveryAttemptCount = 0
        micRecoveryGapAnchor = nil
        return true
    }

    /// Atomically increments and returns the new `deviceSwitchCount`. Use
    /// this instead of `deviceSwitchCount += 1` at every increment site —
    /// the mic path's `recoverFromDeviceChange` and the SCK-path
    /// `recordSystemAudioDeviceSwitch()` below can run concurrently on
    /// different queues.
    @discardableResult
    func incrementDeviceSwitchCount() -> Int {
        deviceSwitchCountLock.lock()
        defer { deviceSwitchCountLock.unlock() }
        _deviceSwitchCount += 1
        return _deviceSwitchCount
    }

    func incrementMicFormatRebuildCount() {
        deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }
        _micFormatRebuildCount += 1
    }

    func resetMicFormatRebuildCount() {
        deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }
        _micFormatRebuildCount = 0
    }

    /// Create a snapshot of recording health info for transcript metadata
    /// using the live `systemAudioStatus`. Used by callers that snapshot
    /// BEFORE calling `stop()`.
    /// `systemAudioCapture` stays type-erased here; the `RecordingHealthInfo`
    /// factory downcasts under `#available(macOS 14.2, *)` internally.
    func createHealthInfo() -> RecordingHealthInfo {
        return RecordingHealthInfo.from(audio: self, systemCapture: recordingSystemAudioCapture)
    }

    /// The tap this recording actually ran. A mic-only recording has none, so
    /// the previous meeting's tap can't grade its health.
    var recordingSystemAudioCapture: (any SystemAudioCaptureEngine & Sendable)? {
        currentRecordingCapturesSystemAudio ? systemAudioCapture : nil
    }

    /// Create a snapshot of recording health info using a pre-captured
    /// `systemAudioStatus`. Use this when snapshotting AFTER `stop()` —
    /// the live status has been reset to `.unknown`, but a real `.failed`
    /// outcome captured before stop must still drive `captureQuality`.
    /// Lock-protected fields (gaps, deviceSwitchCount, recoveryAttemptCount)
    /// are not reset by stop, so they read correctly post-stop without
    /// contending with the audio thread.
    public func createHealthInfo(
        overrideSystemAudioStatus: SystemAudioStatus?
    ) -> RecordingHealthInfo {
        return RecordingHealthInfo.from(
            audio: self,
            systemCapture: recordingSystemAudioCapture,
            overrideSystemAudioStatus: overrideSystemAudioStatus
        )
    }

    func armSystemRecoveryWriteHold() {
        systemRecoveryWriteHoldLock.lock()
        _systemRecoveryWriteHoldCount += 1
        systemRecoveryWriteHoldLock.unlock()
    }
    func releaseSystemRecoveryWriteHold() {
        systemRecoveryWriteHoldLock.lock()
        _systemRecoveryWriteHoldCount = max(0, _systemRecoveryWriteHoldCount - 1)
        systemRecoveryWriteHoldLock.unlock()
    }
    func resetSystemRecoveryWriteHold() {
        systemRecoveryWriteHoldLock.lock()
        _systemRecoveryWriteHoldCount = 0
        systemRecoveryWriteHoldLock.unlock()
    }
    func isHoldingSystemWritesForRecoveryPad() -> Bool {
        systemRecoveryWriteHoldLock.lock()
        defer { systemRecoveryWriteHoldLock.unlock() }
        return _systemRecoveryWriteHoldCount > 0
    }

    @discardableResult
    func beginMicRecovery(for sessionGeneration: UInt64) -> Bool {
        micRecoveryLock.lock()
        defer { micRecoveryLock.unlock() }
        guard _micRecoverySessionGeneration == nil else { return false }
        _micRecoverySessionGeneration = sessionGeneration
        return true
    }

    func endMicRecovery(for sessionGeneration: UInt64) {
        micRecoveryLock.lock()
        defer { micRecoveryLock.unlock() }
        guard _micRecoverySessionGeneration == sessionGeneration else { return }
        _micRecoverySessionGeneration = nil
    }
}
