import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Sleep/wake: the sleep mark that holds mic recovery, and the workspace
// observers that record the gap and kick recovery after wake.
extension Audio {
    /// Awake time a sleep mark may hold mic recovery without its wake
    /// recovery running. `CACurrentMediaTime` stops while the Mac sleeps.
    static let systemSleepHoldAwakeLimit: CFTimeInterval = 30

    func markSystemSleepPending(for sessionGeneration: UInt64) {
        systemSleepPendingLock.lock()
        defer { systemSleepPendingLock.unlock() }
        _systemSleepSequence &+= 1
        _systemSleepMark = SystemSleepMark(
            sessionGeneration: sessionGeneration,
            markedAt: CACurrentMediaTime()
        )
    }

    var systemSleepSequence: UInt64 {
        systemSleepPendingLock.lock()
        defer { systemSleepPendingLock.unlock() }
        return _systemSleepSequence
    }

    /// Clears the mark unless a newer sleep arrived after `sequence` was
    /// read. Returns false when that newer sleep owns the mark.
    @discardableResult
    func clearSystemSleepPending(ifLatest sequence: UInt64? = nil) -> Bool {
        systemSleepPendingLock.lock()
        defer { systemSleepPendingLock.unlock() }
        if let sequence, sequence != _systemSleepSequence { return false }
        _systemSleepMark = nil
        return true
    }

    func isSystemSleepPending(
        for sessionGeneration: UInt64,
        now: CFTimeInterval = CACurrentMediaTime()
    ) -> Bool {
        systemSleepPendingLock.lock()
        defer { systemSleepPendingLock.unlock() }
        guard let mark = _systemSleepMark, mark.sessionGeneration == sessionGeneration else {
            return false
        }
        // A will-sleep whose wake never arrives must not switch mic recovery
        // off for the rest of the meeting.
        guard now - mark.markedAt <= Self.systemSleepHoldAwakeLimit else {
            _systemSleepMark = nil
            return false
        }
        return true
    }

    func installWorkspaceSleepWakeObservers() {
        // MARK: - Sleep/Wake Observers (Phase 1: Invisible Reliability)
        // Handle macOS sleep/wake to prevent AVAudioEngine crashes and log gaps

        sleepObserver = sleepWakeNotifications.center.addObserver(
            forName: sleepWakeNotifications.willSleepName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            // Mark sleep first: releasing the tap can take up to a second,
            // and a route-change mic recovery must not start in that window.
            AppLogger.audio.info("System sleeping during recording - preparing for gap")
            // A lid closed again while the last wake is still settling skips
            // that wake's gap block, so keep the earlier sleep's start and let
            // the next wake record one gap covering both. A start left behind
            // by a will-sleep whose wake never came (its hold has expired) is
            // replaced, so it can't stretch this gap. (A missed wake followed
            // by a sleep inside the 30 s hold still keeps the old start, so
            // that rare gap can overstate by up to 30 s. Metadata only.)
            if self.sleepTimestamp == nil
                || !self.isSystemSleepPending(for: self.recordingSessionGeneration) {
                self.sleepTimestamp = Date()
            }
            self.markSystemSleepPending(for: self.recordingSessionGeneration)
            // A mic-only recording has no tap to release.
            self.recordingSystemAudioCapture?.prepareForSystemSleep()
            self.withAudioGraphLock { self.pinnedMicrophoneCapture }?.prepareForSystemSleep()
        }

        wakeObserver = sleepWakeNotifications.center.addObserver(
            forName: sleepWakeNotifications.didWakeName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            // Bind recovery before either settle delay. A stop/new-start can
            // keep isRecording true while replacing the entire recording, and
            // the old wake must not consume its sleep marker or restart it.
            let sessionGeneration = self.recordingSessionGeneration
            // A mic-only recording has no tap to reconnect.
            let wakingSystemCapture = self.recordingSystemAudioCapture
            // A lid closed again before this wake's delayed recovery runs
            // belongs to the next wake. Running this one would reattach the
            // tap right before sleep and clear the new sleep's mic hold.
            let wakeSleepSequence = self.systemSleepSequence
            AppLogger.audio.info("System waking - waiting for HAL stabilization")

            // Wait 500ms for audio subsystem to stabilize before continuing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isRecording,
                      self.recordingSessionGeneration == sessionGeneration,
                      self.systemSleepSequence == wakeSleepSequence else { return }

                // Record the gap
                if let sleepStart = self.sleepTimestamp {
                    let gap = AudioGap(
                        start: sleepStart,
                        duration: Date().timeIntervalSince(sleepStart),
                        reason: "Sleep/wake"
                    )
                    self.appendRecordingGap(gap)
                    AppLogger.audio.info("Recorded sleep/wake gap", ["gap": gap.description])
                }
                self.sleepTimestamp = nil

                // Always kick both recoveries. CACurrentMediaTime pauses
                // during sleep, so last-buffer timestamps look fresh after
                // lid-open even when SCK is silently stuck. That is why
                // recoverAfterSystemWake exists — do not gate it on stall.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isRecording,
                          self.recordingSessionGeneration == sessionGeneration else { return }
                    // Hand mic recovery back to the watchdog only now, after
                    // the HAL has settled, and run this wake's attempt first.
                    guard self.clearSystemSleepPending(ifLatest: wakeSleepSequence) else {
                        AppLogger.audio.info("Skipping wake recovery; the Mac went back to sleep")
                        return
                    }
                    // A pinned mic that kept running across sleep gets a grace
                    // period, not a rebuild; see PinnedMicrophoneCapture.
                    self.withAudioGraphLock { self.pinnedMicrophoneCapture }?.recoverAfterSystemWake()
                    // A mic still delivering after wake is left alone. Every
                    // rebuild makes a fresh engine that briefly binds to the
                    // macOS default input; with AirPods as the default that
                    // flips them into call mode and garbles their playback.
                    let micBuffersAtWake = self.micBufferCount
                    let micStillDelivering = self.waitForMicBuffer(
                        after: micBuffersAtWake,
                        sessionGeneration: sessionGeneration,
                        timeout: MicWakeRecoveryPolicy.flowingCheckSeconds
                    )
                    let boundDeviceAlive = micStillDelivering ? self.boundMicDeviceIsAlive() : nil
                    if MicWakeRecoveryPolicy.shouldSkipRestart(
                        micStillDelivering: micStillDelivering,
                        boundDeviceAlive: boundDeviceAlive
                    ) {
                        AppLogger.audioMic.info("Microphone still delivering after wake; skipping restart", [
                            "event": "mic_wake_recovery_skipped_flowing"
                        ])
                    } else {
                        if micStillDelivering {
                            AppLogger.audioMic.info("Microphone still delivering after wake but its device is gone; restarting", [
                                "event": "mic_wake_recovery_dead_device"
                            ])
                        }
                        self.recoverFromDeviceChange(
                            sessionGeneration: sessionGeneration,
                            afterSystemWake: true
                        )
                    }
                    // Native mic recovery can block while Stop starts a new
                    // session. Never follow that new session's system backend.
                    guard self.isRecording,
                          self.recordingSessionGeneration == sessionGeneration,
                          self.systemSleepSequence == wakeSleepSequence else { return }
                    wakingSystemCapture?.recoverAfterSystemWake()
                }
            }
        }
    }
}
