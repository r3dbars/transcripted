import Foundation
import Accelerate
@preconcurrency import AVFoundation

// MARK: - Audio Level Processing & Silence Detection

/// Extension handling audio level metering, silence detection, and rolling buffer management.
/// Runs on audio callback threads — NOT @MainActor.
extension Audio {

    // MARK: - Mic Audio Level

    func calculateLevel(buffer: AVAudioPCMBuffer) {
        let level = normalizedRMSLevel(buffer: buffer)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioLevel = level
            self.audioLevelHistory.removeFirst()
            self.audioLevelHistory.append(level)

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

        // Throttle updates: only update every 4th callback (~2x faster than mic instead of ~8x)
        let shouldProcess: Bool = systemLevelLock.withLock {
            systemLevelUpdateCounter += 1
            if systemLevelUpdateCounter >= 4 {
                systemLevelUpdateCounter = 0
                return true
            }
            return false
        }
        guard shouldProcess else { return }

        let level = normalizedRMSLevel(buffer: buffer)

        // Track system audio silence for warning indicator
        updateSystemAudioSilenceTracking(peakLevel: level)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.systemAudioLevelHistory.removeFirst()
            self.systemAudioLevelHistory.append(level)
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
