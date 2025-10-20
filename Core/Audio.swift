import Foundation
import AVFoundation
import AppKit

class Audio: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 25)
    @Published var systemAudioEnabled: Bool = true // Toggle for system audio capture

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var transcription: Transcription
    private var startTime: Date?
    private var timer: Timer?

    // System audio capture components
    private var systemAudioCapture: SystemAudioCapture?
    private var audioMixer: AudioMixer
    private var lastSystemBuffer: AVAudioPCMBuffer?
    private let bufferQueue = DispatchQueue(label: "AudioBufferQueue", qos: .userInitiated)

    init(transcription: Transcription) {
        self.transcription = transcription
        self.audioMixer = AudioMixer()
        setup()
    }

    private func setup() {
        engine = AVAudioEngine()
        inputNode = engine?.inputNode

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print(granted ? "✓ Microphone granted" : "❌ Microphone denied")
        }

        // Initialize system audio capture
        systemAudioCapture = SystemAudioCapture()

        // Load system audio preference
        systemAudioEnabled = UserDefaults.standard.bool(forKey: "systemAudioEnabled")
        if !UserDefaults.standard.object(forKey: "systemAudioEnabled") is Bool {
            // Default to true if not set
            systemAudioEnabled = true
            UserDefaults.standard.set(true, forKey: "systemAudioEnabled")
        }
    }

    func start() {
        guard let engine = engine, let inputNode = inputNode, !isRecording else { return }

        do {
            transcription.start()

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                print("❌ Invalid input format")
                return
            }

            // Start system audio capture if enabled
            if systemAudioEnabled {
                do {
                    try systemAudioCapture?.start { [weak self] systemBuffer in
                        guard let self = self else { return }
                        self.bufferQueue.async {
                            self.lastSystemBuffer = systemBuffer
                        }
                    }
                    print("✓ System audio capture started")
                } catch {
                    print("⚠️ Failed to start system audio: \(error.localizedDescription)")
                    print("ℹ️ Continuing with microphone only")
                }
            }

            // Install tap on microphone
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] micBuffer, _ in
                guard let self = self else { return }

                self.calculateLevel(buffer: micBuffer)

                self.bufferQueue.async {
                    // Get the latest system audio buffer if available
                    let systemBuffer = self.systemAudioEnabled ? self.lastSystemBuffer : nil

                    // Mix microphone and system audio
                    if let mixedBuffer = self.audioMixer.mix(micBuffer: micBuffer, systemBuffer: systemBuffer) {
                        self.transcription.append(mixedBuffer)
                    } else if let convertedMic = self.audioMixer.convertToSpeechFormat(micBuffer) {
                        // Fallback to mic-only if mixing fails
                        self.transcription.append(convertedMic)
                    }
                }
            }

            try engine.start()

            DispatchQueue.main.async {
                self.isRecording = true
                self.startTime = Date()
                self.recordingDuration = 0.0
                self.startTimer()
                NSSound(named: "Tink")?.play()
            }

        } catch {
            print("❌ Failed to start: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        guard let engine = engine, let inputNode = inputNode else { return }

        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Stop system audio capture
        systemAudioCapture?.stop()
        lastSystemBuffer = nil

        transcription.stop()

        // Save transcript to file
        let finalDuration = recordingDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if !self.transcription.currentText.isEmpty {
                TranscriptSaver.save(text: self.transcription.currentText, duration: finalDuration)
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

    deinit {
        stop()
    }
}
