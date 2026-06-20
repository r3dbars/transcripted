import Foundation
@preconcurrency import AVFoundation
import QuartzCore

// MARK: - Audio File Creation & Buffer Management

/// Extension handling audio file creation, WAV writing, buffer copying, and format conversion.
/// Runs on audio callback threads — NOT @MainActor.
extension Audio {

    // MARK: - Audio Capture Setup

    func startAudioCapture(sessionGeneration: UInt64) async throws {
        ensureCaptureInfrastructureConfigured()

        func sessionIsCurrent() -> Bool {
            sessionGeneration == recordingSessionGeneration
        }

        guard sessionIsCurrent() else {
            throw AudioCaptureStaleSessionError()
        }

        let (engine, inputNode, recordingFormat, recordingSnapshot) = try withAudioGraphLock { () throws -> (AVAudioEngine, AVAudioInputNode, AVAudioFormat, AudioRecordingFormatSnapshot) in
            guard sessionIsCurrent() else {
                throw AudioCaptureStaleSessionError()
            }
            let (engine, inputNode) = try ensureEngineInitialized()
            if engine.isRunning {
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "start_recording_reset"
                )
                engine.reset()
                voiceProcessingEnabled = false
                self.inputNode = engine.inputNode
            }
            guard let activeInputNode = self.inputNode else {
                throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine input node unavailable"])
            }
            applyPreferredMeetingInputDevice(to: activeInputNode, operation: "start_recording")
            recordRecordingStartCapturedInput(deviceID: activeInputNode.auAudioUnit.deviceID)
            armVoiceProcessing(on: activeInputNode)

            // When VPIO is off and software AGC is selected, run gain control
            // in the mic tap callback to recover attenuated streams (issue
            // #500). In raw/off mode this deliberately leaves realtimeAGC nil
            // so tuned USB mics are not boosted by Transcripted.
            refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)

            // Read the selected microphone's format after any headset fallback.
            // recordingFormat(for:) returns:
            //   - VPIO output format when armVoiceProcessing enabled it (mono
            //     Float32 at the unit's preferred rate), which matches what the
            //     tap on bus 0 will actually deliver.
            //   - Hardware format via inputFormat(forBus: 1) otherwise — required
            //     because outputFormat(forBus: 0) returns the converter format on
            //     stock AVAudioEngine, which breaks Bluetooth capture.
            let recordingFormat = self.recordingFormat(for: activeInputNode)
            guard let recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat) else {
                AppLogger.audioMic.error("Mic input format invalid", [
                    "sampleRate": "\(recordingFormat.sampleRate)",
                    "channels": "\(recordingFormat.channelCount)"
                ])
                throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
            }

            return (engine, activeInputNode, recordingFormat, recordingSnapshot)
        }
        AppLogger.audioMic.info("Mic input format", [
            "sampleRate": "\(recordingSnapshot.sampleRate)",
            "channels": "\(recordingSnapshot.channelCount)",
            "voiceProcessing": "\(voiceProcessingEnabled)",
            "softwareAGCRequested": "\(enableSoftwareAGC)",
            "softwareAGC": "\(realtimeAGC != nil)"
        ])

        // Start system audio capture
        // CRITICAL: Create audio file BEFORE starting I/O proc to avoid CPU overload
        // Creating files in the audio callback causes HALC_ProxyIOContext::IOWorkLoop overload
        if let capture = systemAudioCapture {
            AppLogger.audioSystem.info("System audio capture object exists, setting up")
            let captureDir = self.paths.audioCaptures
            try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_system.wav")
            AppLogger.audioSystem.info("System audio file URL", ["file": fileURL.lastPathComponent])

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let strongSelf = self else {
                    AppLogger.audioSystem.error("System audio setup: self is nil")
                    return
                }

                func cleanupAbandonedSetup() {
                    strongSelf.systemAudioFileQueue.sync {
                        strongSelf.systemAudioFile = nil
                    }
                    capture.stopSync()
                    try? FileManager.default.removeItem(at: fileURL)
                }

                func sessionIsCurrent() -> Bool {
                    sessionGeneration == strongSelf.recordingSessionGeneration
                }

                AppLogger.audioSystem.info("Starting system audio capture on background thread")

                do {
                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    // Step 1: Prepare the tap (creates aggregate device, gets format)
                    // This does NOT start the I/O proc yet
                    try capture.prepare()

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    // Step 2: Get the format from the tap (now corrected to match device nominal rate)
                    guard let tapFormat = capture.audioFormat else {
                        throw NSError(domain: "Audio", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to get tap format"])
                    }
                    let sampleRate = tapFormat.sampleRate
                    guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
                          tapFormat.channelCount > 0 else {
                        throw NSError(domain: "Audio", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid system audio format"])
                    }
                    AppLogger.audioSystem.info("System audio format", ["sampleRate": AudioRecordingFormatPolicy.displaySampleRate(sampleRate), "channels": "\(tapFormat.channelCount)", "interleaved": "\(tapFormat.isInterleaved)"])

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
                    FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
                    strongSelf.systemAudioFileQueue.sync { strongSelf.systemAudioFile = file }
                    AppLogger.audioSystem.info("System audio file created before I/O proc", ["sampleRate": AudioRecordingFormatPolicy.displaySampleRate(sampleRate), "channels": "\(tapFormat.channelCount)"])

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    // Step 4: Now start the I/O proc with a lightweight callback
                    // The file already exists, so callback only needs to copy+write
                    try capture.start { [weak self] systemBuffer in
                        guard let self = self else { return }
                        guard sessionGeneration == self.recordingSessionGeneration else { return }

                        self.systemBufferCount += 1
                        let currentBufferCount = self.systemBufferCount
                        if currentBufferCount == 1 {
                            // First real buffer: the tap is actually streaming
                            // (not just installed with a file URL). Promote
                            // meeting-capture readiness past `.waiting`.
                            self.markSystemAudioStreamingIfCurrent(sessionGeneration: sessionGeneration)
                        }

                        // Calculate system audio level synchronously (fast, no I/O)
                        self.calculateSystemLevel(buffer: systemBuffer)

                        let bufferForAsyncUse: AVAudioPCMBuffer
                        if capture.deliversOwnedAudioBuffers {
                            bufferForAsyncUse = systemBuffer
                        } else {
                            // CoreAudio process taps use borrowed buffer memory. Copy before any
                            // async consumer sees it.
                            guard let bufferCopy = self.deepCopyBuffer(systemBuffer) else {
                                if currentBufferCount <= 3 {
                                    AppLogger.audioSystem.warning("Failed to copy system audio buffer", ["bufferNumber": "\(currentBufferCount)"])
                                }
                                return
                            }
                            bufferForAsyncUse = bufferCopy
                        }

                        // Debug: Log format details on first few buffers
                        if currentBufferCount <= 3 {
                            let fmt = bufferForAsyncUse.format
                            let bufferSampleRate = AudioRecordingFormatPolicy.displaySampleRate(fmt.sampleRate)
                            AppLogger.audioSystem.debug("System buffer", ["number": "\(currentBufferCount)", "sampleRate": bufferSampleRate, "channels": "\(fmt.channelCount)", "frames": "\(bufferForAsyncUse.frameLength)"])
                        }

                        self.onSystemPCMBuffer?(bufferForAsyncUse)

                        // Dispatch file write to background queue (non-blocking)
                        // File already exists, so this is just a write operation
                        self.systemAudioFileQueue.async { [weak self] in
                            guard let self = self,
                                  self.consecutiveSystemWriteErrors < self.maxConsecutiveWriteErrors,
                                  let audioFile = self.systemAudioFile else { return }
                            do {
                                try audioFile.write(from: bufferForAsyncUse)
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

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    DispatchQueue.main.async {
                        guard sessionGeneration == strongSelf.recordingSessionGeneration else { return }
                        strongSelf.assignSystemAudioFileURLIfCurrent(fileURL, sessionGeneration: sessionGeneration)
                    }
                    AppLogger.audioSystem.info("System audio capture started")

                } catch {
                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }
                    AppLogger.audioSystem.warning("System audio failed", ["error": error.localizedDescription])
                    strongSelf.systemAudioFileQueue.sync {
                        strongSelf.systemAudioFile = nil
                    }
                    try? FileManager.default.removeItem(at: fileURL)
                    DispatchQueue.main.async {
                        strongSelf.error = "System audio unavailable \u{2014} can only record your microphone. To capture Zoom/Teams audio, go to System Settings \u{2192} Privacy & Security \u{2192} System Audio Recording and enable Transcripted."
                        strongSelf.systemAudioFileURL = nil
                        strongSelf.systemAudioFailed = true
                    }
                }
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        do {
            let captureDir = self.paths.audioCaptures
            try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_mic.wav")

            guard sessionIsCurrent() else {
                throw AudioCaptureStaleSessionError()
            }

            self.originalMicAudioFileURL = fileURL
            self.micSegments = [MicRecordingSegment(url: fileURL)]
            DispatchQueue.main.async {
                guard sessionGeneration == self.recordingSessionGeneration else { return }
                self.micAudioFileURL = fileURL
            }

            // Always create mono output format at the hardware sample rate
            let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(
                sampleRate: recordingSnapshot.sampleRate
            )
            self.monoOutputFormat = monoFormat

            // Track channel count for manual downmix
            self.inputChannelCount = recordingSnapshot.channelCount
            if recordingSnapshot.channelCount > 1 {
                AppLogger.audioMic.debug("Will manually downmix to mono", ["channels": "\(recordingSnapshot.channelCount)"])
            }

            // Save as mono WAV file
            micAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
            journalSession = recordingJournal.begin(primaryMicURL: fileURL)
            AppLogger.audioMic.info("Saving as mono", ["sampleRate": "\(recordingSnapshot.sampleRate)"])
        } catch {
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio file: \(error.localizedDescription)"])
        }

        try withAudioGraphLock {
            guard sessionIsCurrent() else {
                throw AudioCaptureStaleSessionError()
            }
            // Remove any existing tap (safety check)
            tearDownInputTapSafely(
                engine: engine,
                inputNode: inputNode,
                operation: "start_recording_install"
            )

            // Install tap on microphone
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }

            do {
                engine.prepare()
                try engine.start()
            } catch {
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "start_recording_failed"
                )
                throw error
            }
        }

        let cueHandler = self.onCaptureLifecycleCue
        await MainActor.run {
            guard sessionGeneration == self.recordingSessionGeneration else { return }
            // isRecording already set in start()
            self.startTime = Date()
            self.recordingDuration = 0.0
            self.startTimer()
            self.startWatchdog()
            cueHandler?(.recordingStarted)
        }
    }

    // MARK: - Mic Buffer Write

    /// Shared mic buffer handler used by both initial tap (startAudioCapture) and recovery tap (recoverFromDeviceChange).
    /// Dispatches mono downmix + file write to micAudioFileQueue.
    ///
    /// When `realtimeAGC` is non-nil (i.e. VPIO is off — the default), gain
    /// is applied to the deep-copied buffer before it reaches the live-
    /// preview consumer and the file write. The level meter intentionally
    /// reads the raw (pre-AGC) buffer so the meter shows actual mic
    /// activity and the silence/inactivity detector still fires when the
    /// room is genuinely quiet. (AGC would otherwise amplify ambient noise
    /// up to "speech-looking" levels and defeat the inactivity prompt.)
    func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lastBufferTime = CACurrentMediaTime()
        let rawPeak = linearPeak(buffer: buffer)

        // Meter + silence detection see the RAW signal so the user's
        // visible level reflects their actual mic input, and the
        // "Still recording?" prompt still triggers in a quiet room.
        calculateLevel(buffer: buffer)

        // The tap-callback buffer is borrowed memory; modify a copy so the
        // CoreAudio-owned original stays untouched. The copy is what the
        // STT consumer callback and the file write see, both of which
        // benefit from AGC's normalized loudness.
        guard let bufferForAsyncUse = deepCopyBuffer(buffer) else {
            AppLogger.audioMic.warning("Failed to copy mic buffer for async write")
            recordMicSignalPeaks(raw: rawPeak, processed: 0, appliedGain: nil, agcMaxGain: nil)
            return
        }

        // Apply real-time AGC to the working copy. No-op when VPIO is on
        // (`agc == nil` records nil gain so the attenuation detector stays
        // dormant). `appliedGain` is read on the same thread that calls
        // process() — the only cross-call read — preserving RealtimeAGC's
        // lock-free single-thread contract.
        let agc = realtimeAGC
        agc?.process(buffer: bufferForAsyncUse)
        recordMicSignalPeaks(
            raw: rawPeak,
            processed: linearPeak(buffer: bufferForAsyncUse),
            appliedGain: agc?.appliedGain,
            agcMaxGain: agc?.maxGain
        )

        self.onMicPCMBuffer?(bufferForAsyncUse)

        micAudioFileQueue.async { [weak self] in
            guard let self = self,
                  self.consecutiveMicWriteErrors < self.maxConsecutiveWriteErrors,
                  let audioFile = self.micAudioFile,
                  let monoFormat = self.monoOutputFormat else { return }

            do {
                if self.inputChannelCount > 1 {
                    guard let monoBuffer = self.manualDownmix(buffer: bufferForAsyncUse, to: monoFormat) else {
                        AppLogger.audioMic.error("Failed to downmix buffer")
                        return
                    }
                    try audioFile.write(from: monoBuffer)
                } else {
                    try audioFile.write(from: bufferForAsyncUse)
                }
                self.consecutiveMicWriteErrors = 0
            } catch {
                self.recordMicWriteFailure(error)
            }
        }
    }

    /// Records one mic file-write failure. Bumps the consecutive-error counter,
    /// logs (rate-limited to the first few and the cap), and — when the cap is
    /// reached — stops the recording and surfaces the error. Once the cap is hit
    /// the writer drops every later buffer (the guard at the top of the
    /// `micAudioFileQueue` block in `handleMicBuffer`), so without this terminal
    /// stop the recording keeps reporting `isRecording == true` and the duration
    /// timer keeps counting while no mic audio is being saved. The common
    /// full-disk cause is already caught by the 30s disk-space check in
    /// `startTimer()`; this covers the non-disk-full stalls (permission/sandbox
    /// loss, file deleted under the handle). Returns true when this failure
    /// tripped the cap. Runs on `micAudioFileQueue`.
    @discardableResult
    func recordMicWriteFailure(_ error: Error) -> Bool {
        consecutiveMicWriteErrors += 1
        let count = consecutiveMicWriteErrors
        if count <= 3 || count == maxConsecutiveWriteErrors {
            AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(count)"])
        }
        guard count >= maxConsecutiveWriteErrors else { return false }
        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
        surfaceWriteFailureAndStop()
        return true
    }

    /// Stops the recording and surfaces a write-failure error, mirroring the
    /// disk-full stop path in `startTimer()`. Callers run on a file-write queue,
    /// so this hops to main. No-ops if recording already ended (a cap crossed
    /// during teardown), so it can't double-stop. The user sees a stopped
    /// recording with a clear reason instead of a dead one that still looks
    /// alive.
    func surfaceWriteFailureAndStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't save audio to disk. Check that there's free space and the save location is still available, then start a new recording."
            self.stop()
        }
    }

    func finalizeMicRecording(primaryURL: URL?, segments: [MicRecordingSegment]) -> URL? {
        guard let primaryURL else { return segments.last?.url }
        guard segments.count > 1 else { return primaryURL }

        let mergeStart = Date()
        do {
            let outcome = try MicRecordingFileMerger.merge(primaryURL: primaryURL, segments: segments)
            let insertedSilenceSamples = segments
                .dropFirst()
                .reduce(0) { partialResult, segment in
                    partialResult + MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000)
                }
            let context: [String: String] = [
                "segments": "\(outcome.segmentCount)",
                "appended": "\(outcome.appendedSegments)",
                "skipped": "\(outcome.skippedSegments)",
                "repaired": "\(outcome.repairedSegments)",
                "padded": "\(outcome.paddedSegments)",
                "durationSeconds": String(format: "%.2f", Date().timeIntervalSince(mergeStart)),
                "insertedSilenceSeconds": String(format: "%.3f", Double(insertedSilenceSamples) / 16_000),
                "file": outcome.url?.lastPathComponent ?? primaryURL.lastPathComponent
            ]
            if outcome.isFullFidelity {
                AppLogger.audioMic.info("Merged mic recovery segments", context)
            } else {
                // Some recorded audio is missing from the merged file; the
                // source segments stay on disk for recovery.
                AppLogger.audioMic.error("Merged mic recovery segments with degraded fidelity", context)
            }
            return outcome.url
        } catch {
            AppLogger.audioMic.error("Failed to merge mic recovery segments", [
                "segments": "\(segments.count)",
                "durationSeconds": String(format: "%.2f", Date().timeIntervalSince(mergeStart)),
                "error": error.localizedDescription
            ])
            return primaryURL
        }
    }

    // MARK: - Timer Management

    func startTimer() {
        timer?.invalidate()
        diskCheckCounter = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }

            // Live issue #500 attenuation detection. Always drain (even when
            // not recording) so an interval never spans ticks. Forcing
            // sawBuffer false while isMicRecovering resets the streak across
            // deliberate/automatic engine restarts. The cue fires directly
            // on main (this timer runs on the main run loop), matching where
            // stop() fires .recordingStopped.
            let interval = self.drainMicSignalIntervalDiagnostics()
            if self.isRecording,
               self.quietMicAttenuationDetector.consume(
                   rawPeak: interval.rawPeak,
                   processedPeak: interval.processedPeak,
                   appliedGain: interval.minAppliedGain,
                   agcMaxGain: interval.agcMaxGain,
                   sawBuffer: interval.sawBuffer && !self.isMicRecovering
               ) {
                let cueHandler = self.onCaptureLifecycleCue
                cueHandler?(.micAttenuatedByForeignVoiceProcessing)
            }

            // Periodic disk check during recording (~every 30s)
            self.diskCheckCounter += 1
            if self.diskCheckCounter >= 150 {
                self.diskCheckCounter = 0
                if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
                   let freeSpace = attrs[FileAttributeKey.systemFreeSize] as? Int64 {
                    if freeSpace < 50_000_000 { // 50MB
                        AppLogger.audio.error("Disk space critically low during recording, stopping", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
                        DispatchQueue.main.async {
                            self.error = "Recording stopped — disk space critically low (\(freeSpace / 1_000_000)MB free)"
                            self.stop()
                        }
                        return
                    } else if freeSpace < 100_000_000 { // 100MB
                        AppLogger.audio.warning("Disk space low during recording", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
                    }
                }
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0.0
    }

    // MARK: - Buffer Utilities

    /// Manually downmix multi-channel mic audio to mono by taking the dominant
    /// channel for this buffer. Averaging can halve a real mic when the second
    /// channel is silent, and opposite-polarity channel pairs can cancel speech.
    func manualDownmix(buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)

        guard channelCount > 0, frameCount > 0 else { return nil }

        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            return nil
        }
        monoBuffer.frameLength = frameCount

        guard let monoData = monoBuffer.floatChannelData?[0] else { return nil }

        let dominantChannel = dominantChannelIndex(buffer: buffer, frameCount: Int(frameCount))

        // Check if buffer is interleaved or non-interleaved
        if buffer.format.isInterleaved {
            // Interleaved: samples are [L0, R0, C0, S0, L1, R1, C1, S1, ...]
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }

            for frame in 0..<Int(frameCount) {
                monoData[frame] = interleavedData[frame * channelCount + dominantChannel]
            }
        } else {
            // Non-interleaved: each channel is a separate array
            guard let channelData = buffer.floatChannelData else { return nil }

            for frame in 0..<Int(frameCount) {
                monoData[frame] = channelData[dominantChannel][frame]
            }
        }

        return monoBuffer
    }

    private func dominantChannelIndex(buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1, frameCount > 0 else { return 0 }

        var bestChannel = 0
        var bestEnergy: Float = -1

        if buffer.format.isInterleaved {
            guard let interleavedData = buffer.floatChannelData?[0] else { return 0 }
            for channel in 0..<channelCount {
                var energy: Float = 0
                for frame in 0..<frameCount {
                    let sample = interleavedData[frame * channelCount + channel]
                    energy += sample * sample
                }
                if energy > bestEnergy {
                    bestEnergy = energy
                    bestChannel = channel
                }
            }
        } else {
            guard let channelData = buffer.floatChannelData else { return 0 }
            for channel in 0..<channelCount {
                var energy: Float = 0
                for frame in 0..<frameCount {
                    let sample = channelData[channel][frame]
                    energy += sample * sample
                }
                if energy > bestEnergy {
                    bestEnergy = energy
                    bestChannel = channel
                }
            }
        }

        return bestChannel
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
