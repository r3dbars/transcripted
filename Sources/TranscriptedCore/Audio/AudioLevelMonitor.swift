import Foundation
import Accelerate
@preconcurrency import AVFoundation
import QuartzCore

// MARK: - Audio Level Processing & Silence Detection

/// Extension handling audio level metering, silence detection, and rolling buffer management.
/// Runs on audio callback threads — NOT @MainActor.
extension Audio {

    // MARK: - Mic Audio Level

    func calculateLevel(buffer: AVAudioPCMBuffer) {
        // Mic buffers arrive ~12x/s; publishing each one fans two @Published
        // mutations out through the capture bridge into SwiftUI observers, so
        // gate publishes to `Audio.levelPublishInterval`. Buffers keep
        // flowing while capture runs, so the next gated publish always
        // carries the freshest level; stop paths reset `audioLevel` to 0
        // directly on main, bypassing this gate. Called on the AVAudioEngine
        // tap thread (not the HAL real-time thread — the tap path already
        // locks and dispatches), so the NSLock is safe here.
        let shouldPublish: Bool = micLevelPublishLock.withLock {
            let now = CACurrentMediaTime()
            guard now - lastMicLevelPublishTime >= Audio.levelPublishInterval else { return false }
            lastMicLevelPublishTime = now
            return true
        }
        guard shouldPublish else { return }

        let level = normalizedRMSLevel(buffer: buffer)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioLevel = level
            // Build the shifted history locally and assign once: each
            // in-place mutation of a @Published array is its own set, so
            // removeFirst + append would emit two objectWillChange fires
            // per gated buffer.
            var history = self.audioLevelHistory
            history.removeFirst()
            history.append(level)
            self.audioLevelHistory = history

            // Silence detection - track how long we've been below threshold
            self.updateSilenceTracking(currentLevel: level)
        }
    }

    func linearPeak(buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0,
              let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }

        if buffer.format.isInterleaved {
            let totalLength = frameCount * vDSP_Length(channelCount)
            var peak: Float = 0
            vDSP_maxmgv(channelData[0], 1, &peak, totalLength)
            return peak.isFinite ? peak : 0
        }

        var peak: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channelData[channel], 1, &channelPeak, frameCount)
            peak = max(peak, channelPeak)
        }
        return peak.isFinite ? peak : 0
    }

    func normalizedRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0,
              let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }

        var sum: Float = 0
        if buffer.format.isInterleaved {
            let totalLength = frameCount * vDSP_Length(channelCount)
            vDSP_dotpr(channelData[0], 1, channelData[0], 1, &sum, totalLength)
        } else {
            for channel in 0..<channelCount {
                var channelSum: Float = 0
                vDSP_dotpr(channelData[channel], 1, channelData[channel], 1, &channelSum, frameCount)
                sum += channelSum
            }
        }

        guard sum.isFinite, sum > 0 else { return 0 }
        let sampleCount = Float(Int(frameCount) * channelCount)
        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sum / sampleCount)
        let power = 20 * log10(max(rms, 0.00001))
        let level = max(0.0, min(1.0, (power + 60) / 60))
        return level.isFinite ? level : 0
    }

    // MARK: - Silence Detection

    /// Updates silence tracking based on current audio level.
    /// `now` is injectable so tests can drive deterministic transitions; production
    /// callers omit it and get the wall-clock time at the call, unchanged.
    func updateSilenceTracking(currentLevel: Float, now: Date = Date()) {
        if currentLevel > silenceThreshold {
            // Audio detected - reset silence tracking
            lastNonSilentTime = now
            isSilent = false
            silenceDuration = 0
        } else {
            // Below threshold - we're in silence
            isSilent = true
            if let lastActive = lastNonSilentTime {
                silenceDuration = now.timeIntervalSince(lastActive)
            } else {
                // First time detecting silence, start tracking
                lastNonSilentTime = now
                silenceDuration = 0
            }
        }
    }

    /// Reset silence tracking (call when recording starts).
    /// `now` is injectable for deterministic tests; production callers omit it.
    func resetSilenceTracking(now: Date = Date()) {
        lastNonSilentTime = now
        silenceDuration = 0
        isSilent = false
    }

    // MARK: - System Audio Level

    func calculateSystemLevel(buffer: AVAudioPCMBuffer) {
        recordSystemSignalPeak(linearPeak(buffer: buffer))

        // System buffers land far more often than mic buffers. Same time-gate
        // as the mic path so the visualizer history publishes on a fixed
        // cadence instead of per callback (the old every-4th-callback counter
        // still updated ~24x/s).
        let shouldProcess: Bool = systemLevelLock.withLock {
            let now = CACurrentMediaTime()
            guard now - lastSystemLevelPublishTime >= Audio.levelPublishInterval else { return false }
            lastSystemLevelPublishTime = now
            return true
        }
        guard shouldProcess else { return }

        let level = normalizedRMSLevel(buffer: buffer)

        // Track system audio silence for warning indicator
        updateSystemAudioSilenceTracking(peakLevel: level)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Single assignment for one publish per gated buffer (see the
            // mic-history comment above).
            var history = self.systemAudioLevelHistory
            history.removeFirst()
            history.append(level)
            self.systemAudioLevelHistory = history
        }
    }

    // MARK: - System Audio Silence Tracking

    /// Tracks prolonged silence in system audio for warning display
    func updateSystemAudioSilenceTracking(peakLevel: Float) {
        let silenceThreshold: Float = 0.001  // Very low threshold for silence

        if peakLevel < silenceThreshold {
            let now = Date()
            // System audio is silent
            if systemAudioSilenceStart == nil {
                systemAudioSilenceStart = now
            }

            guard let silenceStart = systemAudioSilenceStart else { return }
            let silenceDuration = now.timeIntervalSince(silenceStart)
            if silenceDuration > systemAudioSilenceThreshold {
                // Prolonged silence - show warning (but only if not already in a worse state)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.systemAudioStatus == .healthy {
                        self.systemAudioStatus = .silent
                        AppLogger.audioSystem.warning("System audio silent", ["duration": "\(Int(silenceDuration))s"])
                    }
                }
            }
        } else {
            // Audio present - reset silence tracking
            let wasTrackingSilence = systemAudioSilenceStart != nil
            systemAudioSilenceStart = nil
            guard wasTrackingSilence else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only reset to healthy if we were in silent state (not failed/reconnecting)
                if self.systemAudioStatus == .silent {
                    self.systemAudioStatus = .healthy
                }
            }
        }
    }
}
