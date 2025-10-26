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

        // Configure selected microphone if user has chosen one
        if let selectedDeviceID = UserDefaults.standard.string(forKey: "selectedMicrophoneID"),
           !selectedDeviceID.isEmpty {
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
                    for audioDeviceID in audioDevices {
                        var uidAddress = AudioObjectPropertyAddress(
                            mSelector: kAudioDevicePropertyDeviceUID,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                        var uidSize = UInt32(MemoryLayout<CFString>.size)
                        var uid: Unmanaged<CFString>?

                        if AudioObjectGetPropertyData(audioDeviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                           let uidValue = uid?.takeUnretainedValue() as String? {
                            if uidValue == selectedDeviceID {
                                if let inputNode = engine?.inputNode {
                                    do {
                                        try inputNode.auAudioUnit.setDeviceID(audioDeviceID)
                                        print("✓ Using selected microphone (ID: \(audioDeviceID))")
                                    } catch {
                                        print("⚠️ Failed to set device: \(error.localizedDescription)")
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

        // Re-apply selected microphone before starting
        if let selectedDeviceID = UserDefaults.standard.string(forKey: "selectedMicrophoneID"),
           !selectedDeviceID.isEmpty {
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
                    for audioDeviceID in audioDevices {
                        var uidAddress = AudioObjectPropertyAddress(
                            mSelector: kAudioDevicePropertyDeviceUID,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                        var uidSize = UInt32(MemoryLayout<CFString>.size)
                        var uid: Unmanaged<CFString>?

                        if AudioObjectGetPropertyData(audioDeviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                           let uidValue = uid?.takeUnretainedValue() as String? {
                            if uidValue == selectedDeviceID {
                                do {
                                    try inputNode.auAudioUnit.setDeviceID(audioDeviceID)
                                    print("🎤 Set microphone device ID: \(audioDeviceID)")
                                } catch {
                                    print("⚠️ Failed to set device: \(error.localizedDescription)")
                                }
                                break
                            }
                        }
                    }
                }
            }
        }

        // Prepare engine to refresh input node format after device change
        engine.prepare()

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 Recording format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
        }

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
