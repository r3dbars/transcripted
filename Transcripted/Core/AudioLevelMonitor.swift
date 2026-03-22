import Foundation
@preconcurrency import AVFoundation

// MARK: - Audio Level Processing & Silence Detection

/// Extension handling audio level metering, silence detection, and rolling buffer management.
/// Runs on audio callback threads — NOT @MainActor.
@available(macOS 26.0, *)
extension Audio {

    // MARK: - Mic Audio Level

    func calculateLevel(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }

        let channelData = data.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let power = 20 * log10(max(rms, 0.00001))
        let level = max(0.0, min(1.0, (power + 60) / 60))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioLevel = level
            self.audioLevelHistory.removeFirst()
            self.audioLevelHistory.append(level)

            // Silence detection - track how long we've been below threshold
            self.updateSilenceTracking(currentLevel: level)
        }
    }

    // MARK: - Silence Detection

    /// Updates silence tracking based on current audio level
    func updateSilenceTracking(currentLevel: Float) {
        let now = Date()

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

    /// Reset silence tracking (call when recording starts)
    func resetSilenceTracking() {
        lastNonSilentTime = Date()
        silenceDuration = 0
        isSilent = false
    }

    // MARK: - System Audio Level

    func calculateSystemLevel(buffer: AVAudioPCMBuffer) {
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

        guard let data = buffer.floatChannelData else { return }

        let channelData = data.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let power = 20 * log10(max(rms, 0.00001))
        let level = max(0.0, min(1.0, (power + 60) / 60))

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
            // System audio is silent
            if systemAudioSilenceStart == nil {
                systemAudioSilenceStart = Date()
            }

            guard let silenceStart = systemAudioSilenceStart else { return }
            let silenceDuration = Date().timeIntervalSince(silenceStart)
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
            systemAudioSilenceStart = nil
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
