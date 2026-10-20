import Foundation
@preconcurrency import AVFoundation
import Synchronization
import CoreAudio
import Combine

extension CoreAudioSystemAudioCapture {
    /// Releases the tap and aggregate before the Mac sleeps. A tap left
    /// attached to AirPods output across sleep came back delivering zeros and
    /// garbled their playback until they were reconnected. The wake reconnect
    /// then builds a fresh tap on whatever output the Mac woke up with.
    public func prepareForSystemSleep() {
        let released = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            defer { released.signal() }
            guard let self, self.running || self.releasedForSleep else { return }
            self.tapDiagnostics.sleeps += 1
            self.sleepPendingSince = self.clock()
            // Already released: a second lid-close before the last wake's
            // reconnect ran, or a pending rebuild retry. Stay released; this
            // sleep's wake reconnect takes over.
            guard self.running else {
                self.pendingRebuildRetry = nil
                return
            }
            self.releaseForSleep()
        }
        // Finish releasing before the will-sleep handler returns, so nothing
        // is still attached to the output as the Mac sleeps (deep review
        // M14). Bounded, so a slow HAL call on the queue can't hang the
        // caller; the queue itself never waits on the caller.
        if DispatchQueue.getSpecific(key: queueKey) != true {
            _ = released.wait(timeout: .now() + Self.sleepReleaseWaitSeconds)
        }
    }
    public func recoverAfterSystemWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sleepPendingSince = nil
            let wasRunning = self.running || self.releasedForSleep
            self.recover(.systemWake)
            // Also covers a rebuild that failed and is waiting to retry.
            guard wasRunning, self.running || self.releasedForSleep else { return }
            self.silenceWatch = .armed(.wake, at: self.clock())
        }
    }

    private func releaseForSleep() {
        let releaseGeneration = generation
        // Keep the queued tail: it is audio from just before the sleep.
        let tail = ring
        let tailFormat = tapFormat
        destroyHardware()
        releasedForSleep = true
        silenceWatch = nil
        // Sleep settles an open "can't hear the call" report neither way, and
        // no watch is left to see signal return. End it here; the wake watch
        // reports again if the new tap is still deaf. The diagnostic stays.
        tapChangedSinceUnheardReport = false
        unheardPlayback.store(false, ordering: .releasing)
        AppLogger.audioSystem.info("System audio released for sleep")
        if let tail, let tailFormat,
           !tail.formatInvalidated.load(ordering: .acquiring),
           !tail.overflowed.load(ordering: .acquiring) {
            for _ in 0..<tail.capacity {
                guard generation == releaseGeneration,
                      let buffer = tail.pop(format: tailFormat) else { break }
                lastBuffer = clock()
                lastDeliveredEnd = Self.hostSeconds(tail.lastPoppedHostTime).map {
                    $0 + Double(buffer.frameLength) / tailFormat.sampleRate
                }
                if let converted = convertToRecordingFormat(buffer) { callback?(converted) }
            }
        }
        // The host may have stopped from inside the tail callback.
        guard generation == releaseGeneration else { return }
        armReleasedTimer()
    }
}
