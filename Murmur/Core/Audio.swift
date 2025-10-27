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

        // Set flag immediately to prevent concurrent starts
        isRecording = true
        error = nil
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

        // Create mic audio file at native format
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = formatTimestamp(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic.wav")

            DispatchQueue.main.async {
                self.micAudioFileURL = fileURL
            }

            // Save at native recording format (usually 48kHz)
            micAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: recordingFormat.settings,
                commonFormat: recordingFormat.commonFormat,
                interleaved: recordingFormat.isInterleaved
            )
            print("✅ Mic audio: Saving at native \(recordingFormat.sampleRate)Hz")
        } catch {
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio file: \(error.localizedDescription)"])
        }

        // Remove any existing tap (safety check)
        inputNode.removeTap(onBus: 0)

        // Install tap on microphone - write directly to file
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let strongSelf = self else { return }

            // Update watchdog timestamp
            strongSelf.lastBufferTime = Date()

            // Calculate audio level for visualizer
            strongSelf.calculateLevel(buffer: buffer)

            // Write directly to file (no conversion)
            if let audioFile = strongSelf.micAudioFile {
                strongSelf.micAudioFileQueue.async {
                    do {
                        try audioFile.write(from: buffer)
                    } catch {
                        print("❌ Mic audio write failed: \(error.localizedDescription)")
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

            // Create new file segment
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = formatTimestamp(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")

            do {
                micAudioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: recordingFormat.settings,
                    commonFormat: recordingFormat.commonFormat,
                    interleaved: recordingFormat.isInterleaved
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

            // Write to audio file
            if let audioFile = self.micAudioFile {
                self.micAudioFileQueue.async {
                    do {
                        try audioFile.write(from: buffer)
                    } catch {
                        print("❌ Mic audio write failed: \(error.localizedDescription)")
                    }
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
