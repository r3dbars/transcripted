import Foundation
import Darwin
@preconcurrency import AVFoundation
import QuartzCore
import ScreenCaptureKit

// MARK: - Audio File Creation & Buffer Management

/// Extension handling audio file creation, WAV writing, buffer copying, and format conversion.
/// Runs on audio callback threads — NOT @MainActor.
extension Audio {

    // MARK: - Audio Capture Setup

    /// The journal failed before input-tap installation. Retire only this
    /// generation's writer and its new scratch WAV; if Stop already took the
    /// writer, its finalizer (not this failed Start) owns the file.
    @discardableResult
    func discardUnjournaledMicStartFileIfOwned(
        _ fileURL: URL,
        sessionGeneration: UInt64
    ) -> Bool {
        let failedWriter = micAudioFileQueue.sync {
            micAudioFileOwnership.takeWriterOwned(by: sessionGeneration)
        }
        guard let failedWriter else { return false }
        failedWriter.close()
        guard fileURL.deletingLastPathComponent().standardizedFileURL == paths.audioCaptures.standardizedFileURL,
              fileURL.lastPathComponent.hasPrefix("meeting_"),
              fileURL.lastPathComponent.hasSuffix("_mic.wav") else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            AppLogger.audioMic.warning("Could not remove failed-start microphone scratch file", [
                "file": fileURL.lastPathComponent,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    func startAudioCapture(sessionGeneration: UInt64) async throws {
        ensureCaptureInfrastructureConfigured()

        func sessionIsCurrent() -> Bool {
            sessionGeneration == recordingSessionGeneration
        }

        guard sessionIsCurrent() else {
            throw AudioCaptureStaleSessionError()
        }

        // The pinned path records the selected mic through a Core Audio
        // IOProc and never opens the macOS default input. nil means the
        // AVAudioEngine graph below (switch off, voice processing, or an
        // input the pinned recorder can't read).
        let pinnedMicrophone = try preparePinnedMeetingMicrophoneIfEnabled(
            operation: "start_recording",
            sessionGeneration: sessionGeneration
        )
        var preparedGraph: PreparedMeetingInputGraph?
        if pinnedMicrophone == nil {
            preparedGraph = try makeReadyMeetingInputGraph(
                operation: "start_recording",
                resetMeetingSelectionBeforeRetry: true,
                sessionGeneration: sessionGeneration,
                dropsFailedPickOnRetry: true
            )
        }
        guard sessionIsCurrent() else {
            throw AudioCaptureStaleSessionError()
        }
        var recordingFormat: AVAudioFormat
        var recordingSnapshot: AudioRecordingFormatSnapshot
        if let pinnedMicrophone {
            recordingFormat = pinnedMicrophone.recordingFormat
            recordingSnapshot = pinnedMicrophone.recordingSnapshot
            recordRecordingStartCapturedInput(deviceID: pinnedMicrophone.deviceID)
        } else if let preparedGraph {
            recordingFormat = preparedGraph.recordingFormat
            recordingSnapshot = preparedGraph.recordingSnapshot
            recordRecordingStartCapturedInput(deviceID: preparedGraph.inputNode.auAudioUnit.deviceID)
        } else {
            throw AudioCaptureStaleSessionError()
        }

        // When VPIO is off and software AGC is selected, run gain control in
        // the mic tap callback. Raw/off mode deliberately leaves it nil.
        refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)
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
        //
        // Returns nil for a mic-only recording, so it never builds the tap.
        if let capture = makeSystemAudioCaptureForRecordingAttempt() {
            let captureAttempt = SystemAudioCaptureStartAttempt(capture: capture)
            AppLogger.audioSystem.info("System audio capture object exists, setting up")
            let captureDir = self.paths.audioCaptures
            try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_system.wav")
            AppLogger.audioSystem.info("System audio file URL", ["file": fileURL.lastPathComponent])

            var displacedAttempt:
                SystemAudioCaptureAttemptOwnership<
                    SystemAudioCaptureStartAttempt,
                    AVAudioFile
                >.Attempt?
            let claimedSetup = systemAudioFileQueue.sync {
                displacedAttempt = systemAudioCaptureAttemptOwnership.begin(
                    generation: sessionGeneration,
                    capture: captureAttempt
                )
                return systemAudioCaptureAttemptOwnership.owns(
                    generation: sessionGeneration,
                    capture: captureAttempt
                )
            }
            guard claimedSetup else {
                throw AudioCaptureStaleSessionError()
            }
            if let displacedAttempt {
                systemAudioSetupQueue.async {
                    displacedAttempt.capture.finishAndDrain()
                    self.systemAudioFileQueue.async { displacedAttempt.writer?.close() }
                }
            }

            // Each attempt owns a fresh capture engine, so a blocked prepare from
            // an older generation cannot hold up or stop this setup.
            systemAudioSetupQueue.async { [weak self] in
                guard let strongSelf = self else {
                    AppLogger.audioSystem.error("System audio setup: self is nil")
                    return
                }

                func cleanupAbandonedSetup() {
                    // A Stop that lands mid-setup also abandons it. Once that
                    // Stop has handed this WAV off, the file is the recording.
                    guard captureAttempt.mayDiscardAbandonedSetupFile(fileURL) else {
                        AppLogger.audioSystem.info("Stop owns the system audio file; setup leaves it to finalize")
                        return
                    }
                    let abandonedWriter = strongSelf.systemAudioFileQueue.sync {
                        strongSelf.systemAudioCaptureAttemptOwnership.takeWriterOwned(
                            by: sessionGeneration,
                            capture: captureAttempt
                        )
                    }
                    abandonedWriter?.close()
                    let captureIsOwnedByAnotherAttempt = strongSelf.systemAudioFileQueue.sync {
                        guard let current =
                            strongSelf.systemAudioCaptureAttemptOwnership.current else {
                            return false
                        }
                        return current.generation != sessionGeneration
                            && current.captureID == ObjectIdentifier(captureAttempt)
                    }
                    if !captureIsOwnedByAnotherAttempt {
                        captureAttempt.cancel()
                    }
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
                    try captureAttempt.prepare()

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
                    let installed = strongSelf.systemAudioFileQueue.sync {
                        strongSelf.systemAudioCaptureAttemptOwnership.install(
                            file,
                            generation: sessionGeneration,
                            capture: captureAttempt,
                            fileURL: fileURL
                        )
                    }
                    guard installed else {
                        file.close()
                        cleanupAbandonedSetup()
                        return
                    }
                    // Publish + journal at create so stop can resolve the URL
                    // even if I/O start is still in flight.
                    strongSelf.publishSystemAudioFileURLAtCreation(
                        fileURL,
                        sessionGeneration: sessionGeneration
                    )
                    AppLogger.audioSystem.info("System audio file created before I/O proc", ["sampleRate": AudioRecordingFormatPolicy.displaySampleRate(sampleRate), "channels": "\(tapFormat.channelCount)"])

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    // Step 4: Now start the I/O proc with a lightweight callback
                    // The file already exists, so callback only needs to copy+write
                    let started = try captureAttempt.startIfNotCancelled { [weak self] systemBuffer in
                        captureAttempt.observeSignal(systemBuffer)
                        guard let self = self else { return }
                        guard sessionGeneration == self.recordingSessionGeneration else {
                            // Only explicit synchronous finish can deliver the
                            // predecessor tail. Capture its writer, never look up
                            // a newer recording's mutable ownership or format.
                            captureAttempt.enqueueFinishingBuffer(systemBuffer, writer: file, queue: self.systemAudioFileQueue) { error in
                                    self.recordSystemWriteFailure(error, generation: sessionGeneration, bufferNumber: 0)
                            }
                            return
                        }

                        self.systemBufferCount += 1
                        self.lastSystemBufferTime = CACurrentMediaTime()
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

                        if self.isHoldingSystemWritesForRecoveryPad() {
                            return
                        }

                        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(
                            for: bufferForAsyncUse
                        )
                        switch self.systemAudioWriteBackpressure.admit(
                            bytes: retainedBytes,
                            generation: sessionGeneration
                        ) {
                        case .accepted:
                            break
                        case .firstOverflow:
                            AppLogger.audioSystem.error("System audio write backlog exceeded memory limit", [
                                "limitBytes": "\(self.systemAudioWriteBackpressure.byteLimit)"
                            ])
                            self.surfaceSystemWriteBackpressureAndStop(
                                generation: sessionGeneration
                            )
                            return
                        case .closed:
                            captureAttempt.enqueueFinishingBuffer(bufferForAsyncUse, writer: file, queue: self.systemAudioFileQueue) { error in
                                self.recordSystemWriteFailure(error, generation: sessionGeneration, bufferNumber: currentBufferCount)
                            }
                            return
                        }

                        // The reservation is made before dispatch, so a slow
                        // writer can retain at most the gate's byte limit.
                        let backpressure = self.systemAudioWriteBackpressure
                        self.systemAudioFileQueue.async { [weak self] in
                            defer { backpressure.release(bytes: retainedBytes) }
                            guard let self = self,
                                  let writeErrorCount = self.systemWriteErrorCount(
                                    generation: sessionGeneration
                                  ),
                                  writeErrorCount < self.maxConsecutiveWriteErrors else { return }
                            do {
                                // Producer shutdown fences this enqueue before
                                // close. A successor can replace ownership while
                                // this callback is in flight, so retain its exact
                                // original writer instead of re-resolving it.
                                try file.write(from: bufferForAsyncUse)
                                self.recordSystemWriteSuccess(generation: sessionGeneration)
                            } catch {
                                self.recordSystemWriteFailure(
                                    error,
                                    generation: sessionGeneration,
                                    bufferNumber: currentBufferCount
                                )
                            }
                        }
                    }
                    guard started else {
                        cleanupAbandonedSetup()
                        return
                    }

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    AppLogger.audioSystem.info("System audio capture started")

                } catch {
                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }
                    AppLogger.audioSystem.warning("System audio failed", ["error": error.localizedDescription])
                    guard captureAttempt.mayDiscardAbandonedSetupFile(fileURL) else { return }
                    let failedWriter = strongSelf.systemAudioFileQueue.sync {
                        strongSelf.systemAudioCaptureAttemptOwnership.takeWriterOwned(
                            by: sessionGeneration,
                            capture: captureAttempt
                        )
                    }
                    failedWriter?.close()
                    try? FileManager.default.removeItem(at: fileURL)
                    DispatchQueue.main.async {
                        guard strongSelf.recordingSessionGeneration == sessionGeneration else {
                            return
                        }
                        strongSelf.recordSystemAudioStartPermissionDenial(
                            SystemAudioCaptureFailureCopy.isExplicitPermissionDenial(error)
                        )
                        strongSelf.systemAudioFileURL = nil
                        // The WAV was just removed; the stop path must not
                        // hand the pipeline a URL for a file that no longer
                        // exists, or the meeting is stamped as having a
                        // system track it never had.
                        strongSelf.originalSystemAudioFileURL = nil
                        strongSelf.recordSystemAudioStartFailure()
                        strongSelf.error = SystemAudioCaptureFailureCopy.message(for: error)
                    }
                }
            }
        }

        // AirPods can flip to their call profile after the graph above was
        // validated. Rebuild on the settled route before the mic file is
        // sized for the old rate; installTap would otherwise have to refuse it.
        // The pinned recorder keeps one format and resamples any later
        // device format itself, so only the engine graph needs this.
        if let unsettledGraph = preparedGraph {
            let settledGraph = try settleMeetingInputGraphFormat(
                unsettledGraph,
                operation: "start_recording",
                sessionGeneration: sessionGeneration
            )
            if settledGraph.engine !== unsettledGraph.engine {
                preparedGraph = settledGraph
                recordingFormat = settledGraph.recordingFormat
                recordingSnapshot = settledGraph.recordingSnapshot
                recordRecordingStartCapturedInput(deviceID: settledGraph.inputNode.auAudioUnit.deviceID)
                refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)
                AppLogger.audioMic.info("Mic input format after route settled", [
                    "sampleRate": "\(recordingSnapshot.sampleRate)",
                    "channels": "\(recordingSnapshot.channelCount)",
                    "voiceProcessing": "\(voiceProcessingEnabled)"
                ])
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        let micWriteContext: MicPCMWriteContext
        do {
            let captureDir = self.paths.audioCaptures
            try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_mic.wav")
            let journalURL = captureDir.appendingPathComponent(
                fileURL.deletingPathExtension().lastPathComponent
                    + MeetingRecordingJournalStore.filenameSuffix
            )

            // A timestamp collision must not let AVAudioFile truncate an
            // earlier recording before begin() can reject its journal.
            guard !FileManager.default.fileExists(atPath: fileURL.path),
                  !FileManager.default.fileExists(atPath: journalURL.path) else {
                throw MeetingRecordingJournalStartError.alreadyExists
            }

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
            micWriteContext = MicPCMWriteContext(
                generation: sessionGeneration,
                monoFormat: monoFormat,
                inputChannelCount: recordingSnapshot.channelCount
            )

            // Track channel count for manual downmix
            self.inputChannelCount = recordingSnapshot.channelCount
            if recordingSnapshot.channelCount > 1 {
                AppLogger.audioMic.debug("Will manually downmix to mono", ["channels": "\(recordingSnapshot.channelCount)"])
            }

            // Save as mono WAV file
            let newMicAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            let writerInstall = micAudioFileQueue.sync {
                micAudioFileOwnership.installSessionWriter(
                    newMicAudioFile,
                    generation: sessionGeneration
                )
            }
            guard writerInstall.didInstall else {
                newMicAudioFile.close()
                try? FileManager.default.removeItem(at: fileURL)
                throw AudioCaptureStaleSessionError()
            }
            writerInstall.displacedWriter?.close()
            FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
            do {
                journalSession = try recordingJournal.begin(
                    primaryMicURL: fileURL,
                    languageSelection: languageSelectionForCurrentRecording,
                    micOnlyByChoice: !currentRecordingCapturesSystemAudio
                )
            } catch {
                // The input tap is not installed yet. Close only the writer
                // this start still owns, then remove only its newly-created
                // header-only WAV; a concurrent stop may already have taken
                // ownership, in which case its finalizer owns the file.
                discardUnjournaledMicStartFileIfOwned(
                    fileURL,
                    sessionGeneration: sessionGeneration
                )
                if sessionIsCurrent() {
                    originalMicAudioFileURL = nil
                    micSegments = []
                    DispatchQueue.main.async {
                        guard sessionGeneration == self.recordingSessionGeneration else { return }
                        self.micAudioFileURL = nil
                    }
                }
                throw error
            }
            if let systemURL = originalSystemAudioFileURL {
                recordingJournal.recordSystemAudio(systemURL, session: journalSession)
            }
            AppLogger.audioMic.info("Saving as mono", ["sampleRate": "\(recordingSnapshot.sampleRate)"])
        } catch let error as MeetingRecordingJournalStartError {
            await MainActor.run {
                guard sessionGeneration == self.recordingSessionGeneration else { return }
                self.recordStartFailureStage(.microphoneFile)
            }
            throw error
        } catch {
            await MainActor.run {
                guard sessionGeneration == self.recordingSessionGeneration else { return }
                self.recordStartFailureStage(.microphoneFile)
            }
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio file: \(error.localizedDescription)"])
        }

        if let pinnedMicrophone {
            try startPinnedMeetingMicrophone(
                pinnedMicrophone,
                writeContext: micWriteContext,
                sessionGeneration: sessionGeneration
            )
        } else if let preparedGraph {
            let engine = preparedGraph.engine
            let inputNode = preparedGraph.inputNode
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

                try ensureMicTapFormatStillMatches(
                    recordingFormat,
                    on: inputNode,
                    voiceProcessingEnabled: preparedGraph.voiceProcessingEnabled,
                    operation: "start_recording"
                )
                // Install tap on microphone. The route can still move after
                // the check above; the guard makes that a failed start, not a crash.
                try AudioTapInstallGuard.run(operation: "start_recording") {
                    inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                        self?.handleMicBuffer(buffer, writeContext: micWriteContext)
                    }
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
        }

        let cueHandler = self.onCaptureLifecycleCue
        await MainActor.run {
            guard sessionGeneration == self.recordingSessionGeneration else { return }
            // isRecording already set in start()
            self.startTime = Date()
            self.recordingDuration = 0.0
            self.startTimer()
            cueHandler?(.recordingStarted)
        }
    }
}
