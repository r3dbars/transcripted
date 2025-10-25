import Foundation
@preconcurrency import AVFoundation
import AppKit
import Speech
import CoreAudio

@available(macOS 26.0, *)
class Audio: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15) // System audio visualizer

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var transcription: Transcription
    private var startTime: Date?
    private var timer: Timer?

    // System audio capture components
    private var systemAudioCapture: Any? // SystemAudioCapture (macOS 14.2+)
    private var audioMixer: AudioMixer
    private var systemAudioRingBuffer: [Float] = [] // Accumulate system audio samples
    private let systemAudioLock = NSLock()

    // Audio file recording for post-processing
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    private let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)
    @Published var systemAudioFileURL: URL?
    @Published var micAudioFileURL: URL?

    // System audio saved at 48kHz (proven actual rate, not tap's claimed 96kHz)
    private var needsPostConversion = false

    // Debug monitoring
    private let monitor = AudioDebugMonitor.shared
    private var extractCount = 0  // Track ring buffer extractions for logging
    private var captureStartTime: Date?  // Track timing correlation

    // Optimal audio format from SpeechAnalyzer (queried once at startup)
    private var optimalAudioFormat: AVAudioFormat?

    /// Returns true if the app is busy (recording or processing transcription)
    var isBusy: Bool {
        return isRecording || transcription.isProcessing
    }

    init(transcription: Transcription) {
        self.transcription = transcription
        self.audioMixer = AudioMixer()
        setup()

        // Format will be queried on-demand when recording starts
    }

    private func setup() {
        engine = AVAudioEngine()

        // Configure selected microphone if user has chosen one
        if let selectedDeviceID = UserDefaults.standard.string(forKey: "selectedMicrophoneID"),
           !selectedDeviceID.isEmpty {
            // Find matching audio device by UID
            var deviceID = AudioDeviceID(0)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize = UInt32(0)
            var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

            if status == noErr {
                let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
                var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)
                status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &audioDevices)

                if status == noErr {
                    // Find device matching the saved UID
                    for deviceID in audioDevices {
                        var uidAddress = AudioObjectPropertyAddress(
                            mSelector: kAudioDevicePropertyDeviceUID,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                        var uidSize = UInt32(MemoryLayout<CFString>.size)
                        var uid: CFString = "" as CFString

                        if AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr {
                            if (uid as String) == selectedDeviceID {
                                // Set this device as the input for the audio engine
                                if let inputNode = engine?.inputNode {
                                    do {
                                        try inputNode.auAudioUnit.setDeviceID(deviceID)
                                        monitor.log("Using selected microphone (ID: \(deviceID))", level: .info)
                                    } catch {
                                        monitor.log("Failed to set device: \(error.localizedDescription)", level: .warning)
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }
        }

        inputNode = engine?.inputNode

        // Log which input device is actually being used
        if let inputNode = inputNode {
            let format = inputNode.outputFormat(forBus: 0)
            monitor.log("🎤 Input device: \(format.sampleRate)Hz, \(format.channelCount) channels", level: .info)
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            // Microphone permission handled silently
        }

        // Initialize system audio capture (requires macOS 14.2+)
        systemAudioCapture = SystemAudioCapture()
    }

    /// Query optimal audio format from SpeechAnalyzer once at initialization
    /// ALWAYS ensures we have a valid Int16 format (required by transcription engine)
    private func queryOptimalAudioFormat() async {
        // Create temporary transcriber to query format
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // Use on-device for format query
            reportingOptions: [],
            attributeOptions: []
        )

        // Query the best format for SpeechAnalyzer
        let queriedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        if let queriedFormat = queriedFormat {
            monitor.log("SpeechAnalyzer suggested: \(queriedFormat.sampleRate)Hz, \(queriedFormat.channelCount)ch, \(queriedFormat.commonFormat.rawValue)", level: .info)

            // CRITICAL: SpeechAnalyzer may suggest Float32, but the actual transcription engine
            // requires Int16. Force Int16 format using the proper initializer.
            self.optimalAudioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: queriedFormat.sampleRate,
                channels: AVAudioChannelCount(queriedFormat.channelCount),
                interleaved: true
            )

            if let optimalFormat = self.optimalAudioFormat {
                monitor.log("Using Int16 override: \(optimalFormat.sampleRate)Hz, \(optimalFormat.channelCount)ch, Int16", level: .info)
            } else {
                // Format creation failed - use 16kHz mono Int16 fallback
                monitor.log("Format creation failed, using 16kHz Int16 fallback", level: .warning)
                self.optimalAudioFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 16000.0,
                    channels: 1,
                    interleaved: true
                )
            }
        } else {
            monitor.log("SpeechAnalyzer query returned nil, using 16kHz Int16 fallback", level: .warning)
            self.optimalAudioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000.0,
                channels: 1,
                interleaved: true
            )
        }

        // Final safety check - this should NEVER be nil
        if self.optimalAudioFormat == nil {
            monitor.log("CRITICAL: Format is still nil after query, forcing 16kHz Int16 fallback", level: .error)
            self.optimalAudioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000.0,
                channels: 1,
                interleaved: true
            )
        }
    }

    func start() {
        guard !isRecording else { return }

        // Prevent starting new recording while still processing previous one
        if transcription.isProcessing {
            monitor.log("Cannot start recording: still processing previous transcript", level: .warning)
            Task { @MainActor in
                transcription.error = "Still processing previous recording..."
                // Clear error after 3 seconds
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                transcription.error = nil
            }
            return
        }

        monitor.reset()
        monitor.log("Starting audio capture", level: .info)

        // Start audio capture (no transcription initialization needed - happens after recording)
        Task {
            // Ensure optimal format is queried before starting
            if self.optimalAudioFormat == nil {
                await self.queryOptimalAudioFormat()
            }

            do {
                try await self.startAudioCapture()
            } catch {
                await MainActor.run {
                    self.stop()
                }
            }
        }
    }

    private func startAudioCapture() async throws {
        guard let engine = engine, let inputNode = inputNode else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

            // Re-apply selected microphone before starting (in case it wasn't set properly in setup)
            if let selectedDeviceID = UserDefaults.standard.string(forKey: "selectedMicrophoneID"),
               !selectedDeviceID.isEmpty {

                // Use CoreAudio to find and set the device
                var propertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                var dataSize = UInt32(0)
                var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

                if status == noErr {
                    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
                    var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)
                    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &audioDevices)

                    if status == noErr {
                        for deviceID in audioDevices {
                            var uidAddress = AudioObjectPropertyAddress(
                                mSelector: kAudioDevicePropertyDeviceUID,
                                mScope: kAudioObjectPropertyScopeGlobal,
                                mElement: kAudioObjectPropertyElementMain
                            )
                            var uidSize = UInt32(MemoryLayout<CFString>.size)
                            var uid: CFString = "" as CFString

                            if AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr {
                                if (uid as String) == selectedDeviceID {
                                    do {
                                        try inputNode.auAudioUnit.setDeviceID(deviceID)
                                        monitor.log("🎤 Set microphone device ID: \(deviceID)", level: .success)
                                    } catch {
                                        monitor.log("⚠️ Failed to set device: \(error.localizedDescription)", level: .warning)
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
            }

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            monitor.log("🎤 Recording format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch", level: .info)

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
            }

            // Start system audio capture (macOS 14.2+)
            // Run asynchronously to avoid blocking the UI thread
            if let capture = systemAudioCapture as? SystemAudioCapture {
                // Prepare system audio file URL for post-processing transcription
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let fileURL = documentsPath.appendingPathComponent("system_audio_\(timestamp).wav")

                await MainActor.run {
                    self.systemAudioFileURL = fileURL
                }

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }

                    do {
                        var systemBufferCount = 0
                        try capture.start { [weak self] systemBuffer in
                            guard let self = self else { return }

                            systemBufferCount += 1

                            // Create audio file on first buffer
                            if self.systemAudioFile == nil, let fileURL = self.systemAudioFileURL {
                                do {
                                    let nativeFormat = systemBuffer.format
                                    let tapClaimedRate = nativeFormat.sampleRate
                                    let channelCount = Int(nativeFormat.channelCount)

                                    // FIX: CoreAudio tap LIES about sample rate
                                    // Tap claims 96kHz but delivers 48kHz data (proven by test)
                                    // Force 48kHz label for correct playback
                                    let actualRate = 48000.0

                                    if abs(tapClaimedRate - actualRate) > 1000 {
                                        self.monitor.log("⚠️ Tap claims \(Int(tapClaimedRate))Hz but actual is \(Int(actualRate))Hz", level: .warning)
                                    }

                                    let correctedSettings: [String: Any] = [
                                        AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: actualRate,  // Use ACTUAL rate (48kHz)
                                        AVNumberOfChannelsKey: channelCount,
                                        AVLinearPCMBitDepthKey: 32,
                                        AVLinearPCMIsFloatKey: true,
                                        AVLinearPCMIsBigEndianKey: false,
                                        AVLinearPCMIsNonInterleaved: false
                                    ]

                                    self.systemAudioFile = try AVAudioFile(
                                        forWriting: fileURL,
                                        settings: correctedSettings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: true
                                    )

                                    self.needsPostConversion = true  // Will convert 48k→16k after recording
                                    self.monitor.log("✅ System audio: Saving at actual 48kHz (tap claimed \(Int(tapClaimedRate))Hz)", level: .success)

                                } catch {
                                    self.monitor.log("❌ Failed to create system audio file: \(error.localizedDescription)", level: .error)
                                }
                            }

                            // Write buffer to file (labeled correctly as 48kHz)
                            if let audioFile = self.systemAudioFile {
                                do {
                                    try audioFile.write(from: systemBuffer)
                                } catch {
                                    self.monitor.log("❌ File write failed: \(error.localizedDescription)", level: .error)
                                }
                            }

                            // Accumulate system audio samples in ring buffer (for visualizer only now)
                            guard let channelData = systemBuffer.floatChannelData else { return }
                            let frameLength = Int(systemBuffer.frameLength)

                            // Downmix stereo to mono by averaging channels
                            var samples: [Float] = []
                            if systemBuffer.format.channelCount == 2 {
                                // Stereo - average left and right
                                let leftChannel = UnsafeBufferPointer(start: channelData[0], count: frameLength)
                                let rightChannel = UnsafeBufferPointer(start: channelData[1], count: frameLength)
                                samples = (0..<frameLength).map { (leftChannel[$0] + rightChannel[$0]) / 2.0 }
                            } else {
                                // Mono - just use it
                                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                            }

                            // Calculate system audio level for visualizer
                            self.calculateSystemLevel(buffer: systemBuffer)

                            self.systemAudioLock.lock()
                            self.systemAudioRingBuffer.append(contentsOf: samples)
                            // Increased buffer size to handle bursts better - 5 seconds worth at 96kHz
                            let maxBufferSize = 96000 * 5
                            if self.systemAudioRingBuffer.count > maxBufferSize {
                                self.systemAudioRingBuffer.removeFirst(self.systemAudioRingBuffer.count - maxBufferSize)
                            }
                            self.systemAudioLock.unlock()
                        }
                        self.monitor.log("System audio capture started", level: .success)
                    } catch {
                        self.monitor.log("System audio failed: \(error.localizedDescription)", level: .warning)
                    }
                }
                }

            // Create mic audio file for post-processing transcription
            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let fileURL = documentsPath.appendingPathComponent("mic_audio_\(timestamp).wav")

                await MainActor.run {
                    self.micAudioFileURL = fileURL
                }

                // Use optimal format from SpeechAnalyzer if available, otherwise fallback to 16kHz Int16 mono
                if let optimalFormat = self.optimalAudioFormat {
                    micAudioFile = try AVAudioFile(forWriting: fileURL, settings: optimalFormat.settings, commonFormat: optimalFormat.commonFormat, interleaved: optimalFormat.isInterleaved)
                    self.monitor.log("Created mic file with optimal format: \(optimalFormat.sampleRate)Hz", level: .info)
                } else {
                    // Fallback to 16kHz Int16 mono if format query failed
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16000.0,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    micAudioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
                    self.monitor.log("Created mic file with fallback format (16kHz Int16)", level: .warning)
                }
            } catch {
                self.monitor.log("Failed to create mic audio file: \(error.localizedDescription)", level: .error)
            }

            // Install tap on microphone - write to file for post-processing
            // CRITICAL: Remove any existing tap first to avoid "tap already exists" crash
            inputNode.removeTap(onBus: 0)

            // CRITICAL: Use nil format to let AVAudioEngine use the native hardware format
            // This avoids format mismatches when system audio tap claims different rates
            var frameCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] micBuffer, _ in
                guard let self = self else { return }

                // Debug: Log first buffer to confirm mic is capturing
                frameCount += 1
                if frameCount == 1 {
                    // Check audio level to see if mic is actually picking up sound
                    var maxSample: Float = 0.0
                    if let channelData = micBuffer.floatChannelData {
                        let frameLength = Int(micBuffer.frameLength)
                        for i in 0..<frameLength {
                            let sample = abs(channelData[0][i])
                            maxSample = max(maxSample, sample)
                        }
                    }
                    self.monitor.log("🎤 First mic buffer: \(micBuffer.frameLength) frames at \(micBuffer.format.sampleRate)Hz, peak level: \(maxSample)", level: .info)
                }

                // Calculate level on real-time thread (lightweight operation)
                self.calculateLevel(buffer: micBuffer)

                // Write mic audio to file on background queue
                if let audioFile = self.micAudioFile, let fileFormat = audioFile.fileFormat as AVAudioFormat? {
                    // Convert buffer to file format if needed
                    guard let converter = AVAudioConverter(from: micBuffer.format, to: fileFormat) else {
                        self.monitor.log("Failed to create mic audio converter", level: .error)
                        return
                    }

                    // Configure converter for high quality
                    converter.sampleRateConverterQuality = .max
                    converter.dither = true

                    // Create output buffer in file format
                    let capacity = AVAudioFrameCount(Double(micBuffer.frameLength) * fileFormat.sampleRate / micBuffer.format.sampleRate) + 1
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else {
                        self.monitor.log("Failed to create mic audio buffer", level: .error)
                        return
                    }

                    var error: NSError?
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return micBuffer
                    }

                    if let error = error {
                        self.monitor.log("Mic audio conversion error: \(error.localizedDescription)", level: .error)
                        return
                    }

                    // Write to file on background queue
                    self.micAudioFileQueue.async {
                        do {
                            try audioFile.write(from: convertedBuffer)
                            // Log every 100 writes to confirm audio is flowing
                            if frameCount % 100 == 0 {
                                self.monitor.log("🎤 Mic audio writing... (\(frameCount) buffers)", level: .info)
                            }
                        } catch {
                            self.monitor.log("Failed to write mic audio: \(error.localizedDescription)", level: .error)
                        }
                    }
                }
            }

            try engine.start()

            await MainActor.run {
                self.isRecording = true
                self.startTime = Date()
                self.captureStartTime = Date()  // Track timing for diagnostics
                self.recordingDuration = 0.0
                self.startTimer()
                NSSound(named: "Tink")?.play()
            }
    }

    func stop() {
        // Capture processing start time for performance metrics
        let processingStartTime = Date()

        guard let engine = engine, let inputNode = inputNode else { return }

        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Stop system audio capture
        if let capture = systemAudioCapture as? SystemAudioCapture {
            capture.stop()
        }

        // Close mic audio file
        if micAudioFile != nil {
            self.micAudioFile = nil
        }

        // Close system audio file
        if systemAudioFile != nil {
            self.systemAudioFile = nil
        }

        // Clear buffers
        systemAudioLock.lock()
        systemAudioRingBuffer.removeAll()
        systemAudioLock.unlock()

        monitor.log("Audio capture stopped", level: .info)

        // Calculate recording duration
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0.0

        // Convert system audio from 48kHz → 16kHz, then transcribe both files
        if let micURL = micAudioFileURL, let sysURL = systemAudioFileURL {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    monitor.log("Converting system audio 48kHz → 16kHz...", level: .info)

                    // Convert system audio 48kHz → 16kHz for transcription
                    let convertedURL = try await convertSystemAudio(from: sysURL)

                    monitor.log("✅ System audio converted to 16kHz", level: .success)

                    // Transcribe both files (mic already 16kHz, system now converted to 16kHz)
                    try await transcription.transcribeBothFiles(
                        micURL: micURL,
                        systemURL: convertedURL,
                        recordingDuration: duration,
                        processingStartTime: processingStartTime
                    )

                    // Reset transcription state for next recording session
                    monitor.log("✅ Transcription complete, ready for next session", level: .success)
                    transcription.resetForNextRecording()

                    // Clear audio file URLs
                    await MainActor.run {
                        self.micAudioFileURL = nil
                        self.systemAudioFileURL = nil
                    }
                } catch {
                    monitor.log("❌ Transcription failed: \(error.localizedDescription)", level: .error)

                    // Set error message for user
                    await MainActor.run {
                        transcription.error = "Transcription failed: \(error.localizedDescription)"
                    }

                    // Reset state even on error so app can recover
                    transcription.resetForNextRecording()

                    // Clear audio file URLs
                    await MainActor.run {
                        self.micAudioFileURL = nil
                        self.systemAudioFileURL = nil
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.stopTimer()
            NSSound(named: "Pop")?.play()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0.0
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) {
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

        DispatchQueue.main.async {
            self.audioLevel = level
            self.audioLevelHistory.removeFirst()
            self.audioLevelHistory.append(level)
        }
    }

    private func calculateSystemLevel(buffer: AVAudioPCMBuffer) {
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

        DispatchQueue.main.async {
            self.systemAudioLevelHistory.removeFirst()
            self.systemAudioLevelHistory.append(level)
        }
    }

    /// Copy a buffer for async processing
    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        // Copy audio data based on format
        if let srcInt16 = buffer.int16ChannelData, let dstInt16 = copy.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstInt16[channel], srcInt16[channel], Int(buffer.frameLength) * MemoryLayout<Int16>.size)
            }
        } else if let srcFloat = buffer.floatChannelData, let dstFloat = copy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstFloat[channel], srcFloat[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        } else if let srcInt32 = buffer.int32ChannelData, let dstInt32 = copy.int32ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstInt32[channel], srcInt32[channel], Int(buffer.frameLength) * MemoryLayout<Int32>.size)
            }
        }

        return copy
    }

    /// Convert system audio from 48kHz → 16kHz Int16 for transcription
    private func convertSystemAudio(from sourceURL: URL) async throws -> URL {
        // Read 48kHz Float32 file
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat

        // Target: 16kHz Int16 mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,  // Convert to mono
            interleaved: true
        ) else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
        }

        converter.sampleRateConverterQuality = .max
        converter.dither = true

        // Create output file
        let outputURL = sourceURL.deletingPathExtension().appendingPathExtension("16k.wav")
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )

        // Convert in chunks
        let totalFrames = AVAudioFramePosition(sourceFile.length)
        let chunkSize: AVAudioFrameCount = 4096

        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - framesRead)
            let framesToRead = min(chunkSize, remaining)

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create input buffer"])
            }

            try sourceFile.read(into: inputBuffer, frameCount: framesToRead)

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                throw NSError(domain: "Audio", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let error = error {
                throw error
            }

            if status == .error {
                throw NSError(domain: "Audio", code: 5, userInfo: [NSLocalizedDescriptionKey: "Conversion failed"])
            }

            try outputFile.write(from: outputBuffer)
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)
        }

        return outputURL
    }

    deinit {
        stop()
    }
}
