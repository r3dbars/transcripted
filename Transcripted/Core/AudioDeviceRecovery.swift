import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreAudio

// MARK: - Device Recovery & Watchdog

/// Extension handling mic device recovery, watchdog timer, and sleep/wake resilience.
/// Runs on background threads — NOT @MainActor.
@available(macOS 26.0, *)
extension Audio {

    // MARK: - Watchdog Timer

    func startWatchdog() {
        lastBufferTime = Date()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            let timeSinceLastBuffer = Date().timeIntervalSince(self.lastBufferTime)

            if timeSinceLastBuffer > 3.0 {
                // Enforce cooldown — don't attempt recovery more often than every 5s
                if let lastRecovery = self.lastRecoveryTime,
                   Date().timeIntervalSince(lastRecovery) < self.recoveryCooldown {
                    return  // Too soon, skip this tick
                }

                // Give up after too many failed recoveries
                if self.deviceSwitchCount >= self.maxRecoveryAttempts {
                    AppLogger.audioMic.error("Max recovery attempts reached, stopping recording", [
                        "attempts": "\(self.deviceSwitchCount)"
                    ])
                    DispatchQueue.main.async {
                        self.error = "Audio device unavailable — recording stopped"
                        self.stop()
                    }
                    return
                }

                // Audio stopped → device likely changed
                AppLogger.audioMic.warning("Audio device disconnected or changed, switching to default")
                // Dispatch to background — recovery uses Thread.sleep for HAL settle time
                DispatchQueue.global(qos: .userInitiated).async {
                    self.recoverFromDeviceChange()
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Device Recovery

    func recoverFromDeviceChange() {
        // CRITICAL: Prevent concurrent recovery attempts
        // AVAudioEngine notifications can fire multiple times during rapid device changes
        guard !isMicRecovering else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        isMicRecovering = true
        defer { isMicRecovering = false }
        lastRecoveryTime = Date()

        guard let engine = engine, let inputNode = inputNode else { return }

        // Track device switch for health monitoring
        let switchStart = Date()
        deviceSwitchCount += 1
        AppLogger.audioMic.debug("Recovering from device change", ["switchNumber": "\(deviceSwitchCount)", "maxAttempts": "\(maxRecoveryAttempts)"])

        // Stop engine (but keep recording flag true)
        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Reset to system default (ignore UserDefaults preference during recovery)
        engine.reset()
        self.inputNode = engine.inputNode

        // Get new device format
        guard let newInputNode = self.inputNode else {
            AppLogger.audioMic.error("Failed to get input node after reset")
            return
        }

        // HAL settle time - wait for audio hardware to stabilize after device change
        // Same approach as SystemAudioCapture recovery
        Thread.sleep(forTimeInterval: 0.1)  // 100ms

        // Get ACTUAL hardware format (not converter format)
        let recordingFormat = newInputNode.inputFormat(forBus: 1)
        let oldChannelCount = self.inputChannelCount
        AppLogger.audioMic.info("Switched to default device", ["sampleRate": "\(recordingFormat.sampleRate)", "channels": "\(recordingFormat.channelCount)"])

        // ALWAYS update channel count for proper downmix handling
        // This was a bug: if only channel count changed (not sample rate), downmix wouldn't work
        self.inputChannelCount = recordingFormat.channelCount
        if recordingFormat.channelCount > 1 && oldChannelCount != recordingFormat.channelCount {
            AppLogger.audioMic.debug("Recovery: will manually downmix to mono", ["channels": "\(recordingFormat.channelCount)"])
        }

        // Check if we need to create a new file due to format change
        // Must check BOTH sample rate AND channel count changes
        // All micAudioFile accesses wrapped in micAudioFileQueue.sync for thread safety
        let sampleRateChanged = micAudioFileQueue.sync { micAudioFile.map { recordingFormat.sampleRate != $0.processingFormat.sampleRate } ?? false }
        let channelCountChanged = oldChannelCount != recordingFormat.channelCount

        if sampleRateChanged || channelCountChanged {
            let changeReason = sampleRateChanged ? "Sample rate" : "Channel count"
            AppLogger.audioMic.warning("Format changed, closing old file and creating new segment", ["reason": changeReason])
            micAudioFileQueue.sync { micAudioFile = nil }

            // Create new file segment as mono
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")

            do {
                // Always create mono format at new sample rate
                guard let monoFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: recordingFormat.sampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    AppLogger.audioMic.error("Failed to create mono format for recovery")
                    return
                }
                self.monoOutputFormat = monoFormat

                let newFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: monoFormat.settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
                // Security: restrict to owner-only (600) — recovery segment contains biometric
                // voice data and should not be world-readable while recording is in progress.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                micAudioFileQueue.sync { micAudioFile = newFile }
                AppLogger.audioMic.info("Created recovery audio file", ["file": fileURL.lastPathComponent])

                // Update file URL reference
                DispatchQueue.main.async {
                    self.micAudioFileURL = fileURL
                }
            } catch {
                AppLogger.audioMic.error("Failed to create recovery audio file", ["error": error.localizedDescription])
                return
            }
        }

        // Reinstall tap
        newInputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Update watchdog timestamp
            self.lastBufferTime = Date()

            // Calculate audio level for visualizer
            self.calculateLevel(buffer: buffer)

            // Convert to mono if needed, then write to file
            // Note: Use weak self in nested async to prevent retain cycle
            self.micAudioFileQueue.async { [weak self] in
                guard let self = self,
                      self.consecutiveMicWriteErrors < self.maxConsecutiveWriteErrors,
                      let audioFile = self.micAudioFile,
                      let monoFormat = self.monoOutputFormat else { return }

                do {
                    if self.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = self.manualDownmix(buffer: buffer, to: monoFormat) else {
                            AppLogger.audioMic.error("Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                    self.consecutiveMicWriteErrors = 0
                } catch {
                    self.consecutiveMicWriteErrors += 1
                    if self.consecutiveMicWriteErrors <= 3 || self.consecutiveMicWriteErrors == self.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(self.consecutiveMicWriteErrors)"])
                    }
                    if self.consecutiveMicWriteErrors >= self.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
                    }
                }
            }
        }

        // Restart engine
        do {
            try engine.start()
            lastBufferTime = Date() // Reset watchdog

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = "Switched to default mic"

                // Clear error after 3 seconds (use weak self to prevent retain)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.error == "Switched to default mic" {
                        self.error = nil
                    }
                }
            }

            // Record the device switch gap
            let gap = AudioGap(
                start: switchStart,
                duration: Date().timeIntervalSince(switchStart),
                reason: "Device switch"
            )
            recordingGaps.append(gap)
            AppLogger.audioMic.info("Device recovery complete, recording continues", ["gap": gap.description])
        } catch {
            AppLogger.audioMic.error("Failed to restart engine", ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = "Failed to recover from device change"
                self.stop()
            }
        }
    }
}
