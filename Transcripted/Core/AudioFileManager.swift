import Foundation
@preconcurrency import AVFoundation
import AppKit

// MARK: - Audio File Creation & Buffer Management

/// Extension handling audio file creation, WAV writing, buffer copying, and format conversion.
/// Runs on audio callback threads — NOT @MainActor.
@available(macOS 26.0, *)
extension Audio {

    // MARK: - Audio Capture Setup

    func startAudioCapture() async throws {
        guard let engine = engine, let inputNode = inputNode else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        // Use system default microphone (whatever macOS has configured)
        // CRITICAL: Must use inputFormat(forBus: 1) to get ACTUAL hardware format
        // outputFormat(forBus: 0) returns the converter format, not hardware format
        let hardwareFormat = inputNode.inputFormat(forBus: 1)
        AppLogger.audioMic.info("Hardware format", ["sampleRate": "\(hardwareFormat.sampleRate)", "channels": "\(hardwareFormat.channelCount)"])

        guard hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
        }

        // Use the HARDWARE format for the tap (critical for Bluetooth devices)
        let recordingFormat = hardwareFormat

        // Start system audio capture
        // CRITICAL: Create audio file BEFORE starting I/O proc to avoid CPU overload
        // Creating files in the audio callback causes HALC_ProxyIOContext::IOWorkLoop overload
        if let capture = systemAudioCapture as? SystemAudioCapture {
            AppLogger.audioSystem.info("System audio capture object exists, setting up")
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_system.wav")
            AppLogger.audioSystem.info("System audio file URL", ["file": fileURL.lastPathComponent])

            DispatchQueue.main.async {
                self.systemAudioFileURL = fileURL
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let strongSelf = self else {
                    AppLogger.audioSystem.error("System audio setup: self is nil")
                    return
                }

                AppLogger.audioSystem.info("Starting system audio capture on background thread")

                do {
                    // Step 1: Prepare the tap (creates aggregate device, gets format)
                    // This does NOT start the I/O proc yet
                    try capture.prepare()

                    // Step 2: Get the format from the tap (now corrected to match device nominal rate)
                    guard let tapFormat = capture.audioFormat else {
                        throw NSError(domain: "Audio", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to get tap format"])
                    }
                    let sampleRate = tapFormat.sampleRate
                    AppLogger.audioSystem.info("System audio format", ["sampleRate": "\(Int(sampleRate))", "channels": "\(tapFormat.channelCount)", "interleaved": "\(tapFormat.isInterleaved)"])

                    // Step 3: Create audio file BEFORE starting I/O proc (critical!)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: Int(tapFormat.channelCount),
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: !tapFormat.isInterleaved
                    ]

                    let file = try AVAudioFile(
                        forWriting: fileURL,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: tapFormat.isInterleaved
                    )
                    strongSelf.systemAudioFileQueue.sync { strongSelf.systemAudioFile = file }
                    AppLogger.audioSystem.info("System audio file created before I/O proc", ["sampleRate": "\(Int(sampleRate))", "channels": "\(tapFormat.channelCount)"])

                    // Step 4: Now start the I/O proc with a lightweight callback
                    // The file already exists, so callback only needs to copy+write
                    try capture.start { [weak self] systemBuffer in
                        guard let self = self else { return }

                        self.systemBufferCount += 1
                        let currentBufferCount = self.systemBufferCount

                        // Calculate system audio level synchronously (fast, no I/O)
                        self.calculateSystemLevel(buffer: systemBuffer)

                        // CRITICAL: Copy buffer before async dispatch
                        // System audio uses bufferListNoCopy - memory is only valid during callback
                        guard let bufferCopy = self.deepCopyBuffer(systemBuffer) else {
                            if currentBufferCount <= 3 {
                                AppLogger.audioSystem.warning("Failed to copy system audio buffer", ["bufferNumber": "\(currentBufferCount)"])
                            }
                            return
                        }

                        // Debug: Log format details on first few buffers
                        if currentBufferCount <= 3 {
                            let fmt = bufferCopy.format
                            AppLogger.audioSystem.debug("System buffer", ["number": "\(currentBufferCount)", "sampleRate": "\(Int(fmt.sampleRate))", "channels": "\(fmt.channelCount)", "frames": "\(bufferCopy.frameLength)"])
                        }

                        // Dispatch file write to background queue (non-blocking)
                        // File already exists, so this is just a write operation
                        self.systemAudioFileQueue.async { [weak self] in
                            guard let self = self,
                                  self.consecutiveSystemWriteErrors < self.maxConsecutiveWriteErrors,
                                  let audioFile = self.systemAudioFile else { return }
                            do {
                                try audioFile.write(from: bufferCopy)
                                self.consecutiveSystemWriteErrors = 0
                            } catch {
                                self.consecutiveSystemWriteErrors += 1
                                if self.consecutiveSystemWriteErrors <= 3 || self.consecutiveSystemWriteErrors == self.maxConsecutiveWriteErrors {
                                    AppLogger.audioSystem.error("System audio write failed", ["bufferNumber": "\(currentBufferCount)", "error": error.localizedDescription, "consecutive": "\(self.consecutiveSystemWriteErrors)"])
                                }
                                if self.consecutiveSystemWriteErrors >= self.maxConsecutiveWriteErrors {
                                    AppLogger.audioSystem.error("Too many consecutive system write errors, stopping system writes")
                                }
                            }
                        }
                    }
                    AppLogger.audioSystem.info("System audio capture started")

                } catch {
                    AppLogger.audioSystem.warning("System audio failed", ["error": error.localizedDescription])
                    DispatchQueue.main.async {
                        strongSelf.error = "System audio unavailable - recording mic only"
                    }
                }
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic.wav")

            self.originalMicAudioFileURL = fileURL
            DispatchQueue.main.async {
                self.micAudioFileURL = fileURL
            }

            // Always create mono output format at the hardware sample rate
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: recordingFormat.sampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mono format"])
            }
            self.monoOutputFormat = monoFormat

            // Track channel count for manual downmix
            self.inputChannelCount = recordingFormat.channelCount
            if recordingFormat.channelCount > 1 {
                AppLogger.audioMic.debug("Will manually downmix to mono", ["channels": "\(recordingFormat.channelCount)"])
            }

            // Save as mono WAV file
            micAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            AppLogger.audioMic.info("Saving as mono", ["sampleRate": "\(recordingFormat.sampleRate)"])
        } catch {
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio file: \(error.localizedDescription)"])
        }

        // Remove any existing tap (safety check)
        inputNode.removeTap(onBus: 0)

        // Install tap on microphone
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let strongSelf = self else { return }

            // Update watchdog timestamp
            strongSelf.lastBufferTime = Date()

            // Calculate audio level for visualizer (use original buffer)
            strongSelf.calculateLevel(buffer: buffer)

            // Convert to mono if needed, then write to file
            strongSelf.micAudioFileQueue.async {
                guard strongSelf.consecutiveMicWriteErrors < strongSelf.maxConsecutiveWriteErrors,
                      let audioFile = strongSelf.micAudioFile,
                      let monoFormat = strongSelf.monoOutputFormat else { return }

                do {
                    if strongSelf.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = strongSelf.manualDownmix(buffer: buffer, to: monoFormat) else {
                            AppLogger.audioMic.error("Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                    strongSelf.consecutiveMicWriteErrors = 0
                } catch {
                    strongSelf.consecutiveMicWriteErrors += 1
                    if strongSelf.consecutiveMicWriteErrors <= 3 || strongSelf.consecutiveMicWriteErrors == strongSelf.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(strongSelf.consecutiveMicWriteErrors)"])
                    }
                    if strongSelf.consecutiveMicWriteErrors >= strongSelf.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
                    }
                }
            }
        }

        try engine.start()

        await MainActor.run {
            // isRecording already set in start()
            self.startTime = Date()
            self.recordingDuration = 0.0
            self.startTimer()
            self.startWatchdog()
            NSSound(named: "Tink")?.play()
        }
    }

    // MARK: - Timer Management

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0.0
    }

    // MARK: - Buffer Utilities

    /// Manually downmix multi-channel audio to mono by averaging all channels
    func manualDownmix(buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)

        guard channelCount > 0, frameCount > 0 else { return nil }

        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            return nil
        }
        monoBuffer.frameLength = frameCount

        guard let monoData = monoBuffer.floatChannelData?[0] else { return nil }

        // Check if buffer is interleaved or non-interleaved
        if buffer.format.isInterleaved {
            // Interleaved: samples are [L0, R0, C0, S0, L1, R1, C1, S1, ...]
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }

            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedData[frame * channelCount + channel]
                }
                monoData[frame] = sum / Float(channelCount)
            }
        } else {
            // Non-interleaved: each channel is a separate array
            guard let channelData = buffer.floatChannelData else { return nil }

            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                monoData[frame] = sum / Float(channelCount)
            }
        }

        return monoBuffer
    }

    /// Deep copy an AVAudioPCMBuffer to ensure data safety across async dispatch
    /// Required because system audio buffers use bufferListNoCopy and don't own their memory
    func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        // Copy audio data based on format (interleaved vs non-interleaved)
        if buffer.format.isInterleaved {
            // Interleaved: single contiguous buffer
            if let srcData = buffer.floatChannelData?[0],
               let dstData = copy.floatChannelData?[0] {
                let bytesToCopy = Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
                memcpy(dstData, srcData, bytesToCopy)
            }
        } else {
            // Non-interleaved: separate buffer per channel
            if let srcChannels = buffer.floatChannelData,
               let dstChannels = copy.floatChannelData {
                let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(dstChannels[channel], srcChannels[channel], bytesPerChannel)
                }
            }
        }

        return copy
    }

    // MARK: - System Audio Status

    /// Updates systemAudioStatus based on SystemAudioCapture's error messages
    func updateSystemAudioStatus(fromError errorMessage: String?) {
        guard isRecording else {
            systemAudioStatus = .unknown
            return
        }

        if let message = errorMessage {
            if message.contains("Switched to") {
                // Brief reconnecting state, then back to healthy
                systemAudioStatus = .reconnecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    if self.systemAudioStatus == .reconnecting {
                        self.systemAudioStatus = .healthy
                    }
                }
            } else if message.contains("unavailable") || message.contains("failed") {
                systemAudioStatus = .failed
            }
        } else {
            // No error - status is healthy (if we're recording)
            if systemAudioStatus != .silent {
                systemAudioStatus = .healthy
            }
        }
    }
}
