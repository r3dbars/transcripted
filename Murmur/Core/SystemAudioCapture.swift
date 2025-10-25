import Foundation
import AudioToolbox
import AVFoundation

/// Captures system-wide audio output using CoreAudio process taps (macOS 14.2+)
@available(macOS 14.2, *)
class SystemAudioCapture: ObservableObject {
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?

    private let queue = DispatchQueue(label: "SystemAudioCapture", qos: .userInitiated)
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?

    init() {}

    /// Starts capturing system audio and calls the callback with each buffer
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isCapturing else {
            return
        }

        self.bufferCallback = bufferCallback
        errorMessage = nil

        do {
            try setupSystemAudioTap()
            try startAudioDevice()

            DispatchQueue.main.async {
                self.isCapturing = true
            }
        } catch {
            let errMsg = "Failed to start system audio capture: \(error.localizedDescription)"
            errorMessage = errMsg
            throw error
        }
    }

    /// Stops capturing system audio
    func stop() {
        guard isCapturing else { return }

        cleanup()

        DispatchQueue.main.async {
            self.isCapturing = false
        }
    }

    // MARK: - Private Methods

    private func setupSystemAudioTap() throws {
        // Get the default system output device
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()

        // Get all audio processes to tap system-wide audio
        let allProcesses = try AudioObjectID.readProcessList()

        // Create tap description for system-wide audio (tap all processes)
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: allProcesses)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            throw "Failed to create system audio tap: \(err)"
        }

        self.processTapID = tapID

        // Create aggregate device with the tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur-SystemTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        // Read the tap's audio format
        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        // 🔍 DIAGNOSTIC: Log RAW tap stream description
        print("🔍 TAP RAW AudioStreamBasicDescription:")
        print("   mSampleRate: \(tapStreamDescription!.mSampleRate)")
        print("   mChannelsPerFrame: \(tapStreamDescription!.mChannelsPerFrame)")
        print("   mBitsPerChannel: \(tapStreamDescription!.mBitsPerChannel)")
        print("   mBytesPerFrame: \(tapStreamDescription!.mBytesPerFrame)")
        print("   mBytesPerPacket: \(tapStreamDescription!.mBytesPerPacket)")
        print("   mFramesPerPacket: \(tapStreamDescription!.mFramesPerPacket)")
        print("   mFormatFlags: \(tapStreamDescription!.mFormatFlags)")

        // Create aggregate device
        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }
    }

    private func startAudioDevice() throws {
        guard var streamDescription = tapStreamDescription else {
            throw "Tap stream description not available"
        }

        // CRITICAL FIX: CoreAudio tap lies about sample rate
        // It claims 96kHz but actual hardware delivers 48kHz
        // Force the stream description to 48kHz to match reality
        let actualSampleRate = 48000.0
        if streamDescription.mSampleRate != actualSampleRate {
            AudioDebugMonitor.shared.log("⚠️ Correcting tap sample rate from \(streamDescription.mSampleRate)Hz to \(actualSampleRate)Hz", level: .warning)
            streamDescription.mSampleRate = actualSampleRate
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw "Failed to create AVAudioFormat from tap description"
        }

        // 🔍 DIAGNOSTIC: Log what AVAudioFormat interprets
        print("🔍 AVAudioFormat created from tap (corrected):")
        print("   sampleRate: \(format.sampleRate)")
        print("   channelCount: \(format.channelCount)")
        print("   commonFormat: \(format.commonFormat.rawValue)")
        print("   settings: \(format.settings)")
        print("   isInterleaved: \(format.isInterleaved)")

        // Create I/O proc to receive audio buffers
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self = self, let bufferCallback = self.bufferCallback else { return }

            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    throw "Failed to create PCM buffer"
                }

                // Send buffer to callback
                bufferCallback(buffer)
            } catch {
                // Silently handle buffer errors
            }
        }

        guard err == noErr else {
            throw "Failed to create device I/O proc: \(err)"
        }

        // Start the audio device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw "Failed to start audio device: \(err)"
        }
    }

    private func cleanup() {
        if aggregateDeviceID.isValid {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)

            if let deviceProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }

            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            _ = AudioHardwareDestroyProcessTap(processTapID)
            self.processTapID = .unknown
        }

        bufferCallback = nil
    }

    deinit {
        cleanup()
    }
}
