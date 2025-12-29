import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreAudio

@available(macOS 26.0, *)
class Audio: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published var error: String?

    // Silence detection for "Still Recording?" prompt
    @Published var silenceDuration: TimeInterval = 0.0  // How long we've been in silence
    @Published var isSilent: Bool = false  // True when audio below threshold
    private let silenceThreshold: Float = 0.02  // Audio level below this = silence
    private var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published var micAudioFileURL: URL?
    @Published var systemAudioFileURL: URL?

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var startTime: Date?
    private var timer: Timer?

    // Device change watchdog
    private var lastBufferTime: Date = Date()
    private var watchdogTimer: Timer?

    // System audio capture
    private var systemAudioCapture: Any? // SystemAudioCapture (macOS 14.2+)

    // Audio file recording
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    private let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)

    // Audio format conversion (multi-channel to mono)
    private var monoOutputFormat: AVAudioFormat?
    private var inputChannelCount: AVAudioChannelCount = 1

    // Throttle system audio visualizer updates (skip every other callback)
    private var systemLevelUpdateCounter: Int = 0

    // Callback for when recording completes
    var onRecordingComplete: ((URL?, URL?) -> Void)?

    init() {
        setup()
    }

    private func setup() {
        engine = AVAudioEngine()
        inputNode = engine?.inputNode

        print("ℹ️ Using system default microphone")

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.error = "Microphone permission denied"
                }
            }
        }

        // Initialize system audio capture (macOS 14.2+)
        systemAudioCapture = SystemAudioCapture()
    }

    func start() {
        guard !isRecording else {
            print("⚠️ Already recording, ignoring duplicate start request")
            return
        }

        // Pre-flight validation checks
        let validationResult = RecordingValidator.validateRecordingConditions()
        guard validationResult.isValid else {
            print("❌ Pre-flight check failed: \(validationResult.errorMessage ?? "Unknown error")")
            error = validationResult.errorMessage
            return
        }

        // Set flag immediately to prevent concurrent starts
        isRecording = true
        error = nil
        resetSilenceTracking()  // Start fresh silence tracking
        print("📝 Starting audio capture")

        Task {
            do {
                try await startAudioCapture()
            } catch {
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                    self.isRecording = false  // Reset on failure
                    self.stop()
                }
            }
        }
    }

    private func startAudioCapture() async throws {
        guard let engine = engine, let inputNode = inputNode else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        // Use system default microphone (whatever macOS has configured)
        // CRITICAL: Must use inputFormat(forBus: 1) to get ACTUAL hardware format
        // outputFormat(forBus: 0) returns the converter format, not hardware format
        let hardwareFormat = inputNode.inputFormat(forBus: 1)
        print("🎤 Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch")

        guard hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
        }

        // Use the HARDWARE format for the tap (critical for Bluetooth devices)
        let recordingFormat = hardwareFormat

        // Start system audio capture
        if let capture = systemAudioCapture as? SystemAudioCapture {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = formatTimestamp(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_system.wav")

            DispatchQueue.main.async {
                self.systemAudioFileURL = fileURL
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let strongSelf = self else { return }

                var systemAudioAttempts = 0
                let maxAttempts = 2

                while systemAudioAttempts < maxAttempts {
                    do {
                        try capture.start { [weak self] systemBuffer in
                            guard let self = self else { return }

                            // Create audio file on first buffer
                            if self.systemAudioFile == nil, let fileURL = self.systemAudioFileURL {
                                do {
                                    let nativeFormat = systemBuffer.format

                                    // Save at native 48kHz (actual rate, despite tap claiming 96kHz)
                                    let settings: [String: Any] = [
                                        AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: 48000.0,
                                        AVNumberOfChannelsKey: Int(nativeFormat.channelCount),
                                        AVLinearPCMBitDepthKey: 32,
                                        AVLinearPCMIsFloatKey: true,
                                        AVLinearPCMIsBigEndianKey: false,
                                        AVLinearPCMIsNonInterleaved: false
                                    ]

                                    self.systemAudioFile = try AVAudioFile(
                                        forWriting: fileURL,
                                        settings: settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: true
                                    )

                                    print("✅ System audio: Saving at 48kHz")
                                } catch {
                                    print("❌ Failed to create system audio file: \(error.localizedDescription)")
                                }
                            }

                            // Write buffer to file
                            if let audioFile = self.systemAudioFile {
                                do {
                                    try audioFile.write(from: systemBuffer)
                                } catch {
                                    print("❌ System audio write failed: \(error.localizedDescription)")
                                }
                            }

                            // Calculate system audio level for visualizer
                            self.calculateSystemLevel(buffer: systemBuffer)
                        }
                        print("✓ System audio capture started")
                        break  // Success!
                    } catch {
                        systemAudioAttempts += 1
                        if systemAudioAttempts >= maxAttempts {
                            print("⚠️ System audio failed after \(maxAttempts) attempts: \(error.localizedDescription)")
                            DispatchQueue.main.async {
                                strongSelf.error = "System audio unavailable - recording mic only"
                            }
                        } else {
                            print("⚠️ System audio attempt \(systemAudioAttempts) failed, retrying...")
                            Thread.sleep(forTimeInterval: 0.2)
                        }
                    }
                }
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = formatTimestamp(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic.wav")

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
                print("🔄 Will manually downmix \(recordingFormat.channelCount)ch → mono")
            }

            // Save as mono WAV file
            micAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            print("✅ Mic audio: Saving as mono at \(recordingFormat.sampleRate)Hz")
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
                guard let audioFile = strongSelf.micAudioFile,
                      let monoFormat = strongSelf.monoOutputFormat else { return }

                do {
                    if strongSelf.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = strongSelf.manualDownmix(buffer: buffer, to: monoFormat) else {
                            print("❌ Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                } catch {
                    print("❌ Mic audio write failed: \(error.localizedDescription)")
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

    func stop() {
        guard let engine = engine, let inputNode = inputNode else {
            // Ensure flag reset even on guard failure
            isRecording = false
            return
        }

        print("⏹️ Stopping audio capture")

        // Stop audio engine
        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Stop system audio capture
        if let capture = systemAudioCapture as? SystemAudioCapture {
            capture.stop()
        }

        // Close audio files
        let finalMicURL = micAudioFileURL
        let finalSystemURL = systemAudioFileURL

        if micAudioFile != nil {
            micAudioFile = nil
            print("✓ Mic audio file closed: \(finalMicURL?.lastPathComponent ?? "unknown")")
        }

        if systemAudioFile != nil {
            systemAudioFile = nil
            print("✓ System audio file closed: \(finalSystemURL?.lastPathComponent ?? "unknown")")
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.stopTimer()
            self.stopWatchdog()
            NSSound(named: "Pop")?.play()

            // Notify that recording is complete with file URLs
            self.onRecordingComplete?(finalMicURL, finalSystemURL)
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

    private func startWatchdog() {
        lastBufferTime = Date()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            let timeSinceLastBuffer = Date().timeIntervalSince(self.lastBufferTime)

            if timeSinceLastBuffer > 3.0 {
                // Audio stopped → device likely changed
                print("⚠️ Mic audio device disconnected or changed, switching to default...")
                self.recoverFromDeviceChange()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func recoverFromDeviceChange() {
        guard let engine = engine, let inputNode = inputNode else { return }

        print("🔄 Recovering from device change...")

        // Stop engine (but keep recording flag true)
        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Reset to system default (ignore UserDefaults preference during recovery)
        engine.reset()
        self.inputNode = engine.inputNode

        // Get new device format
        guard let newInputNode = self.inputNode else {
            print("❌ Failed to get input node after reset")
            return
        }

        // Get ACTUAL hardware format (not converter format)
        let recordingFormat = newInputNode.inputFormat(forBus: 1)
        print("🎤 Switched to default device: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        // Check if we need to create a new file due to format change
        if let currentFile = micAudioFile,
           recordingFormat.sampleRate != currentFile.processingFormat.sampleRate {
            print("⚠️ Sample rate changed, closing old file and creating new segment")
            micAudioFile = nil

            // Create new file segment as mono
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = formatTimestamp(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")

            do {
                // Always create mono format
                guard let monoFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: recordingFormat.sampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    print("❌ Failed to create mono format for recovery")
                    return
                }
                self.monoOutputFormat = monoFormat

                // Track channel count for manual downmix
                self.inputChannelCount = recordingFormat.channelCount
                if recordingFormat.channelCount > 1 {
                    print("🔄 Recovery: Will manually downmix \(recordingFormat.channelCount)ch → mono")
                }

                micAudioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: monoFormat.settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
                print("✅ Created recovery audio file: \(fileURL.lastPathComponent)")

                // Update file URL reference
                DispatchQueue.main.async {
                    self.micAudioFileURL = fileURL
                }
            } catch {
                print("❌ Failed to create recovery audio file: \(error.localizedDescription)")
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
            self.micAudioFileQueue.async {
                guard let audioFile = self.micAudioFile,
                      let monoFormat = self.monoOutputFormat else { return }

                do {
                    if self.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = self.manualDownmix(buffer: buffer, to: monoFormat) else {
                            print("❌ Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                } catch {
                    print("❌ Mic audio write failed: \(error.localizedDescription)")
                }
            }
        }

        // Restart engine
        do {
            try engine.start()
            lastBufferTime = Date() // Reset watchdog

            DispatchQueue.main.async {
                self.error = "Switched to default mic"

                // Clear error after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.error == "Switched to default mic" {
                        self.error = nil
                    }
                }
            }

            print("✅ Device recovery complete, recording continues")
        } catch {
            print("❌ Failed to restart engine: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.error = "Failed to recover from device change"
                self.stop()
            }
        }
    }

    /// Manually downmix multi-channel audio to mono by averaging all channels
    private func manualDownmix(buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioLevel = level
            self.audioLevelHistory.removeFirst()
            self.audioLevelHistory.append(level)

            // Silence detection - track how long we've been below threshold
            self.updateSilenceTracking(currentLevel: level)
        }
    }

    /// Updates silence tracking based on current audio level
    private func updateSilenceTracking(currentLevel: Float) {
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

    private func calculateSystemLevel(buffer: AVAudioPCMBuffer) {
        // Throttle updates: only update every 4th callback (~2x faster than mic instead of ~8x)
        systemLevelUpdateCounter += 1
        guard systemLevelUpdateCounter >= 4 else { return }
        systemLevelUpdateCounter = 0

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
            self.systemAudioLevelHistory.removeFirst()
            self.systemAudioLevelHistory.append(level)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter.string(from: date)
    }

    deinit {
        stop()
    }
}
