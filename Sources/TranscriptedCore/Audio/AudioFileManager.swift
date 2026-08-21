import Foundation
@preconcurrency import AVFoundation
import QuartzCore
import ScreenCaptureKit

enum SystemAudioCaptureFailureCopy {
    static func isExplicitPermissionDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func message(for error: Error) -> String {
        if isExplicitPermissionDenial(error) {
            return "System Audio Recording is off. Turn it on for Transcripted in System Settings, then try again."
        }

        return "System audio couldn't start. Try recording again. If it keeps happening, quit and reopen Transcripted."
    }
}

/// Serializes start and stop for one system-audio capture attempt. A stop that
/// arrives during `prepare()` marks the attempt cancelled; a stop that races
/// `start()` waits and then tears it down.
final class SystemAudioCaptureStartAttempt: @unchecked Sendable {
    let capture: any SystemAudioCaptureEngine & Sendable
    private let lifecycleLock = NSLock()
    private var cancelled = false

    init(capture: any SystemAudioCaptureEngine & Sendable) {
        self.capture = capture
    }

    func prepare() throws {
        try capture.prepare()
    }

    @discardableResult
    func startIfNotCancelled(
        bufferCallback: @escaping (AVAudioPCMBuffer) -> Void
    ) throws -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !cancelled else { return false }
        try capture.start(bufferCallback: bufferCallback)
        return true
    }

    func cancel() {
        lifecycleLock.lock()
        cancelled = true
        capture.stopSync()
        lifecycleLock.unlock()
    }
}

/// Lock-backed ownership for one system-audio capture attempt. Stop cancels the
/// capture off-main, then detaches and closes the exact-generation writer from
/// a barrier on its serial file queue after every admitted buffer drains.
final class SystemAudioCaptureAttemptOwnership<Capture, Writer: AnyObject>: @unchecked Sendable {
    struct Attempt {
        let generation: UInt64
        let capture: Capture
        let captureID: ObjectIdentifier
        var writer: Writer?
    }

    private let lock = NSLock()
    private var storedCurrent: Attempt?
    private var invalidatedThroughGeneration: UInt64?

    var current: Attempt? {
        lock.lock()
        defer { lock.unlock() }
        return storedCurrent
    }

    @discardableResult
    func begin(generation: UInt64, capture: Capture) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return nil
        }
        if let storedCurrent, storedCurrent.generation > generation {
            return nil
        }
        let displacedAttempt = storedCurrent
        storedCurrent = Attempt(
            generation: generation,
            capture: capture,
            captureID: ObjectIdentifier(capture as AnyObject),
            writer: nil
        )
        return displacedAttempt
    }

    func install(
        _ writer: Writer,
        generation: UInt64,
        capture: Capture
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var current = storedCurrent,
              current.generation == generation,
              current.captureID == ObjectIdentifier(capture as AnyObject),
              current.writer == nil else {
            return false
        }
        current.writer = writer
        storedCurrent = current
        return true
    }

    func owns(generation: UInt64, capture: Capture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedCurrent?.generation == generation
            && storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject)
    }

    func captureOwned(by generation: UInt64) -> Capture? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation else { return nil }
        return storedCurrent?.capture
    }

    func writerOwned(by generation: UInt64, capture: Capture) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation,
              storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject) else { return nil }
        return storedCurrent?.writer
    }

    func takeWriterOwned(by generation: UInt64, capture: Capture) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation,
              storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject) else { return nil }
        let ownedWriter = storedCurrent?.writer
        storedCurrent?.writer = nil
        return ownedWriter
    }

    func takeAttemptOwned(by generation: UInt64) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation else { return nil }
        let ownedAttempt = storedCurrent
        storedCurrent = nil
        return ownedAttempt
    }

    func takeAttemptOwned(
        by captureGeneration: UInt64,
        invalidatingFor stopGeneration: UInt64
    ) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration {
            self.invalidatedThroughGeneration = max(
                invalidatedThroughGeneration,
                stopGeneration
            )
        } else {
            self.invalidatedThroughGeneration = stopGeneration
        }
        guard storedCurrent?.generation == captureGeneration else { return nil }
        let ownedAttempt = storedCurrent
        storedCurrent = nil
        return ownedAttempt
    }
}

/// Immutable file-write state captured when a mic tap is installed.
///
/// A successor recording may publish a different channel count and mono format
/// while the previous generation's bounded tail is still draining. Keeping the
/// exact tap generation and format in every queued block prevents that old tail
/// from reading successor state.
struct MicPCMWriteContext: @unchecked Sendable {
    let generation: UInt64
    let monoFormat: AVAudioFormat
    let inputChannelCount: AVAudioChannelCount
}

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

        let preparedGraph = try makeReadyMeetingInputGraph(
            operation: "start_recording",
            resetMeetingSelectionBeforeRetry: true,
            sessionGeneration: sessionGeneration
        )
        guard sessionIsCurrent() else {
            throw AudioCaptureStaleSessionError()
        }
        let engine = preparedGraph.engine
        let inputNode = preparedGraph.inputNode
        let recordingFormat = preparedGraph.recordingFormat
        let recordingSnapshot = preparedGraph.recordingSnapshot
        recordRecordingStartCapturedInput(deviceID: inputNode.auAudioUnit.deviceID)

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
                displacedAttempt.writer?.close()
                systemAudioSetupQueue.async {
                    displacedAttempt.capture.cancel()
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
                            capture: captureAttempt
                        )
                    }
                    guard installed else {
                        file.close()
                        cleanupAbandonedSetup()
                        return
                    }
                    AppLogger.audioSystem.info("System audio file created before I/O proc", ["sampleRate": AudioRecordingFormatPolicy.displaySampleRate(sampleRate), "channels": "\(tapFormat.channelCount)"])

                    guard sessionIsCurrent() else {
                        cleanupAbandonedSetup()
                        return
                    }

                    // Step 4: Now start the I/O proc with a lightweight callback
                    // The file already exists, so callback only needs to copy+write
                    let started = try captureAttempt.startIfNotCancelled { [weak self] systemBuffer in
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
                                  writeErrorCount < self.maxConsecutiveWriteErrors,
                                  let audioFile =
                                    self.systemAudioCaptureAttemptOwnership.writerOwned(
                                        by: sessionGeneration,
                                        capture: captureAttempt
                                  ) else { return }
                            do {
                                try audioFile.write(from: bufferForAsyncUse)
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
                        strongSelf.recordSystemAudioStartFailure()
                        strongSelf.error = SystemAudioCaptureFailureCopy.message(for: error)
                    }
                }
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        let micWriteContext: MicPCMWriteContext
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
            journalSession = recordingJournal.begin(primaryMicURL: fileURL)
            AppLogger.audioMic.info("Saving as mono", ["sampleRate": "\(recordingSnapshot.sampleRate)"])
        } catch {
            await MainActor.run {
                guard sessionGeneration == self.recordingSessionGeneration else { return }
                self.recordStartFailureStage(.microphoneFile)
            }
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
                self?.handleMicBuffer(buffer, writeContext: micWriteContext)
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
    func handleMicBuffer(_ buffer: AVAudioPCMBuffer, writeContext: MicPCMWriteContext) {
        let sessionGeneration = writeContext.generation
        guard sessionGeneration == recordingSessionGeneration else { return }
        // Empty callbacks do not prove the input route can deliver audio. Let
        // the start gate and watchdog keep waiting for a real mic frame.
        guard buffer.frameLength > 0 else { return }

        micBufferCount += 1
        if MicWatchdogArmingPolicy.shouldArm(
            afterNonemptyBufferCount: micBufferCount
        ) {
            markMicAudioStreamingIfCurrent(sessionGeneration: sessionGeneration)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.recordingSessionGeneration == sessionGeneration,
                      self.isRecording else { return }
                self.startWatchdog()
            }
        }
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

        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: bufferForAsyncUse)
        switch micAudioWriteBackpressure.admit(
            bytes: retainedBytes,
            generation: sessionGeneration
        ) {
        case .accepted:
            break
        case .firstOverflow:
            AppLogger.audioMic.error("Mic audio write backlog exceeded memory limit", [
                "limitBytes": "\(micAudioWriteBackpressure.byteLimit)"
            ])
            surfaceMicWriteBackpressureAndStop(generation: sessionGeneration)
            return
        case .closed:
            return
        }

        if let hostHandler = onMicPCMBuffer {
            switch micHostPCMBufferFanout.enqueue(
                bufferForAsyncUse,
                generation: sessionGeneration,
                handler: hostHandler
            ) {
            case .accepted:
                break
            case .firstOverflow:
                AppLogger.audioMic.error("Mic host fan-out backlog exceeded memory limit", [
                    "limitBytes": "\(micHostPCMBufferFanout.byteLimit)"
                ])
                surfaceMicWriteBackpressureAndStop(generation: sessionGeneration)
            case .closed:
                break
            }
        }

        let backpressure = micAudioWriteBackpressure
        let monoFormat = writeContext.monoFormat
        let inputChannelCount = writeContext.inputChannelCount
        micAudioFileQueue.async { [weak self] in
            defer { backpressure.release(bytes: retainedBytes) }
            guard let self,
                  let writeErrorCount = self.micWriteErrorCount(
                    generation: sessionGeneration
                  ),
                  writeErrorCount < self.maxConsecutiveWriteErrors,
                  let audioFile = self.micAudioFileOwnership.writerOwned(
                    by: sessionGeneration
                  ) else { return }

            do {
                if inputChannelCount > 1 {
                    guard let monoBuffer = self.manualDownmix(buffer: bufferForAsyncUse, to: monoFormat) else {
                        AppLogger.audioMic.error("Failed to downmix buffer")
                        return
                    }
                    try audioFile.write(from: monoBuffer)
                } else {
                    try audioFile.write(from: bufferForAsyncUse)
                }
                self.recordMicWriteSuccess(generation: sessionGeneration)
            } catch {
                self.recordMicWriteFailure(error, generation: sessionGeneration)
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
    func recordMicWriteFailure(
        _ error: Error,
        generation: UInt64? = nil
    ) -> Bool {
        let generation = generation ?? recordingSessionGeneration
        guard let count = incrementMicWriteError(generation: generation) else {
            return false
        }
        if count <= 3 || count == maxConsecutiveWriteErrors {
            AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(count)"])
        }
        guard count >= maxConsecutiveWriteErrors else { return false }
        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
        surfaceWriteFailureAndStop(generation: generation)
        return true
    }

    @discardableResult
    func recordSystemWriteFailure(
        _ error: Error,
        generation: UInt64? = nil,
        bufferNumber: Int? = nil
    ) -> Bool {
        let generation = generation ?? recordingSessionGeneration
        guard let count = incrementSystemWriteError(generation: generation) else {
            return false
        }
        if count <= 3 || count == maxConsecutiveWriteErrors {
            var context = [
                "error": error.localizedDescription,
                "consecutive": "\(count)"
            ]
            if let bufferNumber {
                context["bufferNumber"] = "\(bufferNumber)"
            }
            AppLogger.audioSystem.error("System audio write failed", context)
        }
        guard count >= maxConsecutiveWriteErrors else { return false }
        AppLogger.audioSystem.error("Too many consecutive system write errors, stopping recording")
        surfaceSystemWriteFailureAndStop(generation: generation)
        return true
    }

    /// Stops the recording and surfaces a write-failure error, mirroring the
    /// disk-full stop path in `startTimer()`. Callers run on a file-write queue,
    /// so this hops to main. No-ops if recording already ended (a cap crossed
    /// during teardown), so it can't double-stop. The user sees a stopped
    /// recording with a clear reason instead of a dead one that still looks
    /// alive.
    func surfaceWriteFailureAndStop(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't save audio to disk. Check that there's free space and the save location is still available, then start a new recording."
            self.stop()
        }
    }

    func surfaceSystemWriteFailureAndStop(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.systemAudioFailed = true
            self.systemAudioStatus = .failed
            self.error = "Recording stopped \u{2014} Transcripted couldn't save system audio to disk. Check that there's free space and the save location is still available, then start a new recording."
            self.stop()
        }
    }

    func surfaceMicWriteBackpressureAndStop(generation: UInt64) {
        guard writeBackpressureStopAdmission.claim(generation: generation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't keep up while saving microphone audio. Your partial recording is preserved. Check the save location, then start a new recording."
            self.stop()
        }
    }

    func surfaceSystemWriteBackpressureAndStop(generation: UInt64) {
        guard writeBackpressureStopAdmission.claim(generation: generation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.systemAudioFailed = true
            self.systemAudioStatus = .failed
            self.error = "Recording stopped \u{2014} Transcripted couldn't keep up while saving system audio. Your partial recording is preserved. Check the save location, then start a new recording."
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

    /// Records a system-audio start failure while the meeting is still in the
    /// asynchronous start phase. The normal error-message status helper
    /// intentionally collapses non-recording state to .unknown, which is
    /// correct after stop but loses the start-failure discriminator here.
    func recordSystemAudioStartFailure() {
        recordStartFailureStage(.systemAudio)
        systemAudioStatus = .failed
        systemAudioFailed = true
    }

    /// Updates systemAudioStatus based on SystemAudioCapture's error messages
    func updateSystemAudioStatus(fromError errorMessage: String?) {
        guard isRecording else {
            systemAudioStatus = .unknown
            return
        }

        if let message = errorMessage {
            let normalizedMessage = message.lowercased()
            if normalizedMessage.contains("reconnecting") {
                // ScreenCaptureKit owns the bounded restart and clears this
                // state by publishing nil after the replacement stream starts.
                systemAudioStatus = .reconnecting
            } else if message.contains("Switched to") {
                // Brief reconnecting state, then back to healthy
                systemAudioStatus = .reconnecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    if self.systemAudioStatus == .reconnecting {
                        self.systemAudioStatus = .healthy
                    }
                }
            } else if normalizedMessage.contains("unavailable") || normalizedMessage.contains("failed") {
                systemAudioStatus = .failed
                systemAudioFailed = true
            }
        } else {
            // No error - status is healthy (if we're recording)
            if systemAudioStatus != .silent {
                systemAudioStatus = .healthy
            }
        }
    }
}
